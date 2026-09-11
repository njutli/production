# T09 DirStats规模测试阶段A只读签收

> 时间：2026-09-11 10:11 CST  
> 裁决：`T09_DIRSTATS_PHASE_A_PASS`  
> 状态变更：仅在157生成并立即删除一份固定路径的status错误输出；未格式化、挂载、创建测试文件或修改服务。

## 关键结论

- 业务卷`juicefs-prod`为JuiceFS `1.4.1+unknown`，UUID=`e1b69ea9-0e3d-427d-bea9-8765928afa66`，`Storage=ceph`、`Bucket=ceph://juicefs-data`、`BlockSize=256 KiB`、`TrashDays=0`、`DirStats=true`；
- 临时META后缀`jfsportal-dirstats-20260911`返回`database is not formatted`，没有覆盖已有卷；
- 157的`/tmp/jfsportal-dirstats-20260911`不存在，临时metrics端口19567未占用，JuiceFS二进制、FUSE、Python和time工具可用；
- 157系统盘879 GiB、仅余20 GiB（98%使用），但inode余量约5629万；`/dev/shm`为504 GiB tmpfs、当前仅用24 KiB，系统可用内存约915 GiB；因此临时file后端改放`/dev/shm`，测试只建零字节文件并禁用metadata backup；
- `/dev/shm`当前唯一可见条目为sunrise用户的1853字节`ps.txt`，可见总占用4 KiB且系统无swap；它仍是系统公共资源，只使用唯一测试子目录并设置64 MiB异常门，不把整个tmpfs视为测试专属空间；
- 150/151/152可用内存约741/817/818 GiB，三节点PD/TiKV PID和`/mnt/jfs-tikv`、`/mnt/dbwal`均存在。

## 监控基线

- Prometheus `sum(up)=14`；Portal、Prometheus、Grafana均为`active/disabled`；
- `ceph_health_status=0`，OSD `6 up/6 in`，PG `64/64 clean`；
- `juicefs-data`约1,978,612 objects、518,631,030,784 bytes stored；
- TiKV pending compaction=0，近1分钟总CPU约0.022核；
- 业务JuiceFS近1分钟FUSE约6 ops/s，读写字节速率均为0。

## 阶段B准入

阶段B仅创建独立临时卷和1万零字节文件canary，生成速率不超过500/s。对象后端固定为`/dev/shm/jfsportal-dirstats-20260911-objects`，系统盘测试目录硬门为100 MiB、tmpfs对象目录硬门为64 MiB。它会向共享TiKV写入独立前缀，因此虽不需sudo，仍须用户确认后执行；阶段C/D不得自动进入。
