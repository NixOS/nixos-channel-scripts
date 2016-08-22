#include <chrono>
#include <regex>

#include "shared.hh"
#include "globals.hh"
#include "eval.hh"
#include "store-api.hh"
#include "common-opts.hh"
#include "get-drvs.hh"
#include "fs-accessor.hh"
#include "thread-pool.hh"
#include "sqlite.hh"

#include <sqlite3.h>

using namespace nix;

static const char * cacheSchema = R"sql(

  create table if not exists StorePaths (
    id   integer primary key autoincrement not null,
    path text unique not null
  );

  create table if not exists StorePathContents (
    storePath integer not null,
    subPath text not null,
    type integer not null,
    fileSize integer,
    isExecutable integer,
    primary key (storePath, subPath),
    foreign key (storePath) references StorePaths(id) on delete cascade
  );

)sql";

static const char * programsSchema = R"sql(

  create table if not exists Programs (
    name        text not null,
    system      text not null,
    package     text not null,
    primary key (name, system, package)
  );

)sql";


void mainWrapped(int argc, char * * argv)
{
    initNix();
    initGC();

    if (argc != 6) throw Error("usage: generate-programs-index CACHE-DB PROGRAMS-DB STORE-URI STORE-PATHS NIXPKGS-PATH");

    Path cacheDbPath = argv[1];
    Path programsDbPath = argv[2];
    Path storePathsFile = argv[4];
    Path nixpkgsPath = argv[5];

    settings.readOnlyMode = true;
    settings.showTrace = true;

    auto localStore = openStore();
    auto binaryCache = openStoreAt(argv[3]);

    struct CacheState
    {
        SQLite db;
        SQLiteStmt queryPath, insertPath, queryFiles, insertFile;
    };

    Sync<CacheState> cacheState_;

    /* Get the allowed store paths to be included in the database. */
    auto allowedPaths = tokenizeString<PathSet>(readFile(storePathsFile, true));

    PathSet allowedPathsClosure;
    for (auto & path : allowedPaths)
        if (!allowedPathsClosure.count(path))
            binaryCache->computeFSClosure(path, allowedPathsClosure);

    printMsg(lvlInfo, format("%d top-level paths, %d paths in closure")
        % allowedPaths.size() % allowedPathsClosure.size());

    /* Initialise the cache database. */
    {
        auto cacheState(cacheState_.lock());

        cacheState->db = SQLite(cacheDbPath);
        cacheState->db.exec("pragma foreign_keys = 1");
        cacheState->db.exec(cacheSchema);

        if (sqlite3_busy_timeout(cacheState->db, 60 * 60 * 1000) != SQLITE_OK)
            throwSQLiteError(cacheState->db, "setting timeout");

        cacheState->queryPath.create(cacheState->db,
            "select id from StorePaths where path = ?");
        cacheState->insertPath.create(cacheState->db,
            "insert or ignore into StorePaths(path) values (?)");
        cacheState->queryFiles.create(cacheState->db,
            "select subPath, type, fileSize, isExecutable from StorePathContents where storePath = ?");
        cacheState->insertFile.create(cacheState->db,
            "insert into StorePathContents(storePath, subPath, type, fileSize, isExecutable) values (?, ?, ?, ?, ?)");
    }

    /* Initialise the programs database. */
    struct ProgramsState
    {
        SQLite db;
        SQLiteStmt insertProgram;
    };

    Sync<ProgramsState> programsState_;

    {
        auto programsState(programsState_.lock());

        programsState->db = SQLite(programsDbPath);
        programsState->db.exec("pragma synchronous = off");
        programsState->db.exec("pragma main.journal_mode = truncate");
        programsState->db.exec(programsSchema);

        programsState->insertProgram.create(programsState->db,
            "insert or replace into Programs(name, system, package) values (?, ?, ?)");
    }

    EvalState state({}, localStore);

    Value vRoot;
    state.eval(state.parseExprFromFile(resolveExprPath(nixpkgsPath)), vRoot);

    /* Get all derivations. */
    DrvInfos packages;

    for (auto system : std::set<std::string>{"x86_64-linux", "i686-linux"}) {
        auto args = state.allocBindings(2);
        Value * vConfig = state.allocValue();
        state.mkAttrs(*vConfig, 0);
        args->push_back(Attr(state.symbols.create("config"), vConfig));
        Value * vSystem = state.allocValue();
        mkString(*vSystem, system);
        args->push_back(Attr(state.symbols.create("system"), vSystem));
        args->sort();
        getDerivations(state, vRoot, "", *args, packages, true);
    }

    /* For each store path, figure out the package with the shortest
       attribute name. E.g. "nix" is preferred over "nixStable". */
    std::map<Path, DrvInfo *> packagesByPath;

    for (auto & package : packages)
        try {
            auto outputs = package.queryOutputs(true);

            for (auto & output : outputs) {
                if (!allowedPathsClosure.count(output.second)) continue;
                auto i = packagesByPath.find(output.second);
                if (i != packagesByPath.end() &&
                    (i->second->attrPath.size() < package.attrPath.size() ||
                     (i->second->attrPath.size() == package.attrPath.size() && i->second->attrPath < package.attrPath)))
                    continue;
                packagesByPath[output.second] = &package;
            }
        } catch (AssertionError & e) {
        } catch (Error & e) {
            e.addPrefix(format("in package ‘%s’: ") % package.attrPath);
            throw;
        }

    /* Return the files in a store path, using a SQLite database to cache the results. */
    auto getFiles = [&](const Path & storePath) {
        std::map<std::string, FSAccessor::Stat> files;

        {
            auto cacheState(cacheState_.lock());
            auto useQueryPath(cacheState->queryPath.use()(storePath));
            if (useQueryPath.next()) {
                auto id = useQueryPath.getInt(0);
                auto useQueryFiles(cacheState->queryFiles.use()(id));
                while (useQueryFiles.next()) {
                    files[useQueryFiles.getStr(0)] = FSAccessor::Stat{
                        (FSAccessor::Type) useQueryFiles.getInt(1), (uint64_t) useQueryFiles.getInt(2), useQueryFiles.getInt(3) != 0};
                }
                return files;
            }
        }

        auto accessor = binaryCache->getFSAccessor();

        /* Get the NAR of the store path and enumerate all files
           inside it. */
        std::function<void(const Path &, const std::string &)> recurse;

        recurse = [&](const Path & curPath,
            const std::string & relPath)
        {
            auto st = accessor->stat(curPath);
            files[relPath] = st;
            if (st.type == FSAccessor::Type::tDirectory) {
                for (auto & name : accessor->readDirectory(curPath))
                    recurse(curPath + "/" + name, relPath.empty() ? name : relPath + "/" + name);
            }
        };

        auto now1 = std::chrono::steady_clock::now();
        recurse(storePath, "");
        auto now2 = std::chrono::steady_clock::now();
        printMsg(lvlInfo, format("processed %s in %d ms")
            % storePath
            % std::chrono::duration_cast<std::chrono::milliseconds>(now2 - now1).count());

        /* Insert the store path into the database. */
        {
            auto cacheState(cacheState_.lock());
            SQLiteTxn txn(cacheState->db);

            if (cacheState->queryPath.use()(storePath).next()) return files;
            cacheState->insertPath.use()(storePath).exec();
            uint64_t id = sqlite3_last_insert_rowid(cacheState->db);

            for (auto & x : files) {
                cacheState->insertFile.use()
                    (id)
                    (x.first)
                    (x.second.type)
                    (x.second.fileSize, x.second.type == FSAccessor::Type::tRegular)
                    (x.second.isExecutable, x.second.type == FSAccessor::Type::tRegular)
                    .exec();
            }

            txn.commit();
        }

        return files;
    };

    /* Note: we don't index hidden files. */
    std::regex isProgram("bin/([^.][^/]*)");

    /* Process each store path. */
    auto doPath = [&](const Path & storePath, DrvInfo * package) {
        try {
            auto files = getFiles(storePath);
            if (files.empty()) return;

            std::set<std::string> programs;

            for (auto & file : files) {
                // FIXME: we assume that symlinks point to
                // programs. Should check that.
                if (file.second.type == FSAccessor::Type::tDirectory ||
                    (file.second.type == FSAccessor::Type::tRegular && !file.second.isExecutable))
                    continue;
                std::smatch match;
                if (std::regex_match(file.first, match, isProgram))
                    programs.insert(match[1]);
            }

            if (programs.empty()) return;

            {
                auto programsState(programsState_.lock());
                SQLiteTxn txn(programsState->db);
                for (auto & program : programs)
                    programsState->insertProgram.use()(program)(package->system)(package->attrPath).exec();
                txn.commit();
            }

        } catch (InvalidPath & e) {
            printMsg(lvlTalkative, format("warning: %s (%s) not in binary cache") % package->attrPath % storePath);
            return;
        }
    };

    /* Enqueue work items for each package. */
    ThreadPool threadPool;

    for (auto & i : packagesByPath)
        threadPool.enqueue(std::bind(doPath, i.first, i.second));

    threadPool.process();
}

int main(int argc, char * * argv)
{
    return handleExceptions(argv[0], [&]() {
        mainWrapped(argc, argv);
    });
}
