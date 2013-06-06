#! /usr/bin/env python
import os
import threading
import sys
import Queue
import random
import subprocess
import urlparse
import boto

def run_tasks(nr_workers, tasks, worker_fun):
    task_queue = Queue.Queue()
    result_queue = Queue.Queue()

    nr_tasks = 0
    for t in tasks: task_queue.put(t); nr_tasks = nr_tasks + 1

    if nr_tasks == 0: return []

    if nr_workers == -1: nr_workers = nr_tasks
    if nr_workers < 1: raise Exception("number of worker threads must be at least 1")

    def thread_fun():
        n = 0
        while True:
            try:
                t = task_queue.get(False)
            except Queue.Empty:
                break
            n = n + 1
            try:
                result_queue.put((worker_fun(t), None, None))
            except Exception as e:
                result_queue.put((None, e, sys.exc_info()[2]))
        #sys.stderr.write("thread {0} did {1} tasks\n".format(threading.current_thread(), n))

    threads = []
    for n in range(nr_workers):
        thr = threading.Thread(target=thread_fun)
        thr.daemon = True
        thr.start()
        threads.append(thr)

    results = []
    while len(results) < nr_tasks:
        try:
            # Use a timeout to allow keyboard interrupts to be
            # processed.  The actual timeout value doesn't matter.
            (res, exc, tb) = result_queue.get(True, 1000)
        except Queue.Empty:
            continue
        if exc:
            raise exc, None, tb
        results.append(res)

    for thr in threads:
        thr.join()

    return results

if len(sys.argv) != 3:
    print 'Usage: upload-s3.py <local-dir> <s3-bucket-name>'
    sys.exit(1)

local_dir = sys.argv[1]
bucket_name = sys.argv[2]

files = [ "{0}/{1}".format(root, f) for root, _, files in os.walk(local_dir) if files != [] for f in files]
files = sorted(files, key=os.path.getsize)

files = [ (i, f) for i, f in enumerate(files) ]
total = len(files)

__lock__ = threading.Lock()

conn = boto.connect_s3()
bucket = boto.connect_s3().get_bucket(bucket_name)

def upload(t):
    (i, local_file) = t
    remote_file = local_file.replace(local_dir+'/','')
    if i % 1000 == 0:
        with __lock__:
            sys.stderr.write("{0}/{1}\n".format(i, total))
    
    if (bucket.get_key(remote_file) is None) and not (".tmp" in remote_file):
        with __lock__:
            sys.stderr.write("Uploading {0}: {1} -> {2}\n".format(i, local_file, remote_file))
        subprocess.call(["s3cmd", "put", local_file, "s3://{0}/{1}".format(bucket_name,remote_file)])

run_tasks(15, files, upload)
