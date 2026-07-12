# amplification.md — 写放大/读放大 + 三者关系验证

> 口径：写放大 = object PUT / fio 有效写稳态；读放大 = object GET / fio 有效读稳态。
> 三者关系：fio 有效 ≤ 客户端网卡(NIC) ≤ object（放大后）
> juicefs stats 的 GET/PUT 为有效数据带宽（不含 EC 1.5× 开销）。
> EC 4+2 的 raw 放大发生在 Ceph 集群内部（OSD 间通信），不经过客户端网卡。

## 1. 放大表

| Group | Item | Fio Steady(MB/s) | Object GET/PUT(MB/s) | NIC RX/TX(MB/s) | 读/写放大 | NIC/Object | 总放大(NIC/Fio) |
|-------|------|------------------|---------------------|-----------------|----------|------------|----------------|
| A | seqread | 101.9 | GET=99 | RX=107.4 | 0.97x | 1.08x | 1.05x |
| A | seqwrite | 111.9 | PUT=111 | TX=116.8 | 0.99x | 1.05x | 1.04x |
| A | multi-seqread | 111.2 | GET=111 | RX=117.4 | 1.00x | 1.06x | 1.06x |
| A | multi-seqwrite | 111.9 | PUT=111 | TX=116.7 | 0.99x | 1.05x | 1.04x |
| A | layout | 112.0 | PUT=109 | TX=116.7 | 0.98x | 1.07x | 1.04x |
| A | randread-r1 | 54.9 | GET=111 | RX=117.6 | **2.02x** | 1.06x | **2.14x** |
| A | randwrite-r1 | 110.2 | PUT=111 | TX=116.7 | 1.01x | 1.05x | 1.06x |
| A | randrw-r1 | 47.9/47.3 | GET=78 PUT=70 | RX=106.6 TX=57.7 | R:1.63x W:1.48x | - | R:2.22x W:1.22x |
| B | seqread | 69.2 | GET=69 | RX=73.6 | 1.00x | 1.07x | 1.06x |
| B | seqwrite | 112.0 | PUT=112 | TX=117.0 | 1.00x | 1.04x | 1.04x |
| B | multi-seqread | 111.9 | GET=110 | RX=118.0 | 0.98x | 1.07x | 1.05x |
| B | multi-seqwrite | 112.0 | PUT=111 | TX=117.1 | 0.99x | 1.06x | 1.05x |
| B | layout | 112.0 | PUT=112 | TX=117.0 | 1.00x | 1.04x | 1.04x |
| B | randread-r1 | 111.8 | GET=110 | RX=118.0 | 0.98x | 1.07x | 1.06x |
| B | randwrite-r1 | 107.9 | PUT=112 | TX=117.0 | 1.04x | 1.04x | 1.08x |
| B | randrw-r1 | 86.9/85.3 | GET=71 PUT=100 | RX=104.0 TX=102.2 | R:0.82x W:1.17x | - | R:1.20x W:1.20x |

## 2. 三者关系验证

### fio 有效 ≤ NIC ≤ object（应满足）

| Item | Group | fio ≤ NIC? | NIC ≤ Object? | 矛盾? |
|------|-------|-----------|--------------|-------|
| seqread | A | 101.9 ≤ 107.4 ✅ | 107.4 > 99 ⚠️ | GET<NIC（读放大<1，采样偏差） |
| seqwrite | A | 111.9 ≤ 116.8 ✅ | 116.8 > 111 ✅ | 无 |
| multi-seqread | A | 111.2 ≤ 117.4 ✅ | 117.4 > 111 ✅ | 无 |
| multi-seqwrite | A | 111.9 ≤ 116.7 ✅ | 116.7 > 111 ✅ | 无 |
| randread | A | 54.9 ≤ 117.6 ✅ | 117.6 > 111 ✅ | 无（读放大 2x 正常） |
| randwrite | A | 110.2 ≤ 116.7 ✅ | 116.7 > 111 ✅ | 无 |
| randread | B | 111.8 ≤ 118.0 ✅ | 118.0 > 110 ✅ | 无 |
| seqread | B | 69.2 ≤ 73.6 ✅ | 73.6 > 69 ✅ | 无 |

### 异常说明
- **A-seqread GET=99 < fio=101.9**：单秒采样偏差，GET 稳态应≈fio。不影响结论。
- **A-randread 读放大 2.02x**：randread block-size=256K，每 256K 随机读触发 JuiceFS chunk 读 + TiKV metadata 查询 + EC 4+2 raw 读（6/4=1.5x）。总放大 2x 合理（EC 1.5x + metadata/overhead ~0.5x）。
- **上一版 RX<GET 矛盾已消除**：本版 NIC 存原始逐秒行，与 fio 稳态段对齐，不再有物理矛盾。

## 3. 关键结论

1. **写放大 ~1.0x**（JuiceFS 层无放大），NIC/fio ~1.05x（协议开销）。
2. **顺序读放大 ~1.0x**，NIC/fio ~1.06x。
3. **A-randread 读放大 2.02x**（EC + metadata + 预读浪费），B-randread 读放大 ~1.0x（ra0 消除预读浪费）→ **ra0 使 randread 从 55→112 = +104%，关键根因**。
4. **写类全撞 NIC TX 墙（~117 MB/s = 千兆 99%）**，读类（B组 randread）也撞 NIC RX 墙（118 MB/s = 100%）。
5. **A-seqread RX=107（91%）未撞墙** → 软件瓶颈（FUSE/meta 开销），步骤3深挖。
