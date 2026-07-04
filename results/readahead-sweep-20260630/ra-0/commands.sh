# readahead sweep: ra=0
juicefs mount -d --cache-size 0 --max-readahead 0 tikv://192.168.11.12:2379/juicefs-prod /mnt/juicefs
