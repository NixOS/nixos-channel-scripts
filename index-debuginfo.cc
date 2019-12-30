#include <nix/config.h>

#include <regex>

#include "shared.hh"
#include "s3-binary-cache-store.hh"
#include "thread-pool.hh"
#include "nar-info.hh"

#include "file-cache.hh"

// cache.nixos.org/debuginfo/<build-id>
//  => redirect to NAR

using namespace nix;

void mainWrapped(int argc, char * * argv)
{
    initNix();

    if (argc != 4) throw Error("usage: index-debuginfo CACHE-DB BINARY-CACHE-URI STORE-PATHS");

    Path cacheDbPath = argv[1];
    std::string binaryCacheUri = argv[2];
    Path storePathsFile = argv[3];

    FileCache fileCache(cacheDbPath);

    if (hasSuffix(binaryCacheUri, "/")) binaryCacheUri.pop_back();
    auto binaryCache = openStore(binaryCacheUri).cast<S3BinaryCacheStore>();

    auto storePaths = binaryCache->parseStorePathSet(tokenizeString<PathSet>(readFile(storePathsFile, true)));

    std::regex debugFileRegex("^lib/debug/\\.build-id/[0-9a-f]{2}/[0-9a-f]{38}\\.debug$");

    ThreadPool threadPool(25);

    auto doFile = [&](std::string member, std::string key, std::string target) {
        checkInterrupt();

        nlohmann::json json;
        json["archive"] = target;
        json["member"] = member;

        // FIXME: or should we overwrite? The previous link may point
        // to a GC'ed file, so overwriting might be useful...
        if (binaryCache->fileExists(key)) return;

        printError("redirecting ‘%s’ to ‘%s’", key, target);

        binaryCache->upsertFile(key, json.dump(), "application/json");
    };

    auto doPath = [&](const Path & storePath) {
        checkInterrupt();

        try {
            auto files = fileCache.getFiles(binaryCache, storePath);

            std::string prefix = "lib/debug/.build-id/";

            for (auto & file : files) {
                if (file.second.type != FSAccessor::Type::tRegular
                    || !std::regex_match(file.first, debugFileRegex))
                    continue;

                std::string buildId =
                    std::string(file.first, prefix.size(), 2)  +
                    std::string(file.first, prefix.size() + 3, 38);

                auto info = binaryCache->queryPathInfo(binaryCache->parseStorePath(storePath)).cast<const NarInfo>();

                assert(hasPrefix(info->url, "nar/"));

                std::string key = "debuginfo/" + buildId;
                std::string target = "../" + info->url;

                threadPool.enqueue(std::bind(doFile, file.first, key, target));
            }

        } catch (BadJSON & e) {
            printError("error: in %s: %s", storePath, e.what());
        }
    };

    for (auto & storePath : storePaths)
        if (hasSuffix(storePath.name(), "-debug"))
            threadPool.enqueue(std::bind(doPath, binaryCache->printStorePath(storePath)));

    threadPool.process();
}

int main(int argc, char * * argv)
{
    return handleExceptions(argv[0], [&]() {
        mainWrapped(argc, argv);
    });
}
