# readahead sweep: ra=default
juicefs mount -d --cache-size 0 tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs

FIO_RAND="fio --directory=/mnt/juicefs/test_dir --name=storage_test --filesize=1G --size=1G --bs=256k --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=100 --create_serialize=0 --group_reporting --time_based --runtime=60s"
