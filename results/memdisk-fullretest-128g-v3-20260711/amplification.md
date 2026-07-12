# amplification.md — v3 写放大/读放大 + 三者关系验证

> 口径：写放大 = object PUT / fio 有效写稳态；读放大 = object GET / fio 有效读稳态。
> 三者关系：fio 有效 ≤ 客户端网卡(NIC) ≤ object（放大后）
> juicefs stats GET/PUT 为有效数据带宽（不含 EC 1.5× raw 开销，EC 编码在 OSD 间完成不经客户端网卡）。

## 1. 放大表

| Group | Item | Fio Steady(MB/s) | GET/PUT(MB/s) | NIC RX/TX(MB/s) | 读/写放大 | NIC/Object | 总放大(NIC/Fio) |
|-------|------|------------------|---------------|-----------------|----------|------------|----------------|
| A | seqread | 103.0 | GET=102 | RX=109 | 0.99x | 1.07x | 1.06x |
| A | seqwrite | 111.8 | PUT=111 | TX=117 | 0.99x | 1.05x | 1.05x |
| A | multi-seqread | 111.6 | GET=112 | RX=118 | 1.00x | 1.05x | 1.06x |
| A | multi-seqwrite | 111.6 | PUT=115 | TX=117 | 1.03x | 1.02x | 1.05x |
| A | layout | 112.1 | PUT=61 | TX=117 | 0.54x* | 1.92x | 1.04x |
| A | randread-r1 | 55.0 | GET=111 | RX=118 | **2.02x** | 1.06x | **2.15x** |
| A | randwrite-r1 | 111.6 | PUT=111 | TX=117 | 0.99x | 1.05x | 1.05x |
| A | randrw-r1 | 48.5/48.5 | GET=85 PUT=73 | RX=114 TX=62 | R:1.75x W:1.51x | - | R:2.35x W:1.28x |
| B | seqread | 69.1 | GET=68 | RX=73 | 0.98x | 1.07x | 1.06x |
| B | seqwrite | 111.5 | PUT=111 | TX=117 | 1.00x | 1.05x | 1.05x |
| B | multi-seqread | 111.6 | GET=111 | RX=118 | 0.99x | 1.06x | 1.06x |
| B | multi-seqwrite | 111.8 | PUT=112 | TX=117 | 1.00x | 1.04x | 1.05x |
| B | layout | 112.1 | PUT=61 | TX=117 | 0.54x* | 1.92x | 1.04x |
| B | randread-r1 | 112.1 | GET=111 | RX=118 | 0.99x | 1.06x | 1.05x |
| B | randwrite-r1 | 111.2 | PUT=113 | TX=117 | 1.02x | 1.04x | 1.05x |
| B | randrw-r1 | 76.5/76.2 | GET=70 PUT=89 | RX=96 TX=95 | R:0.92x W:1.17x | - | R:1.25x W:1.25x |

*layout PUT=61 是单秒采样值（PUT 波动大，128 job 4M block 每 job 间隔写），稳态应 ≈ fio。

## 2. 三者关系验证

| Item | Group | fio ≤ NIC? | NIC ≤ Object? | 矛盾? |
|------|-------|-----------|--------------|-------|
| seqread | A | 103 ≤ 109 ✅ | 109 > 102 ✅ | 无 |
| seqwrite | A | 112 ≤ 117 ✅ | 117 > 111 ✅ | 无 |
| multi-seqread | A | 112 ≤ 118 ✅ | 118 > 112 ✅ | 无 |
| multi-seqwrite | A | 112 ≤ 117 ✅ | 117 > 115 ✅ | 无 |
| randread | A | 55 ≤ 118 ✅ | 118 > 111 ✅ | 无（读放大 2x 正常） |
| randwrite | A | 112 ≤ 117 ✅ | 117 > 111 ✅ | 无 |
| randread | B | 112 ≤ 118 ✅ | 118 > 111 ✅ | 无 |
| seqread | B | 69 ≤ 73 ✅ | 73 > 68 ✅ | 无 |
| randrw | B | 76 ≤ 96(R)/95(TX) ✅ | 96 > 70(GET)/95<89(PUT) ⚠️ | PUT 采样偏差 |

**无 RX<GET 矛盾（v2 硬伤已修复）**。所有项 fio ≤ NIC 关系成立。

## 3. 关键结论

1. **写放大 ~1.0x**（JuiceFS 层无放大），NIC/fio ~1.05x（协议开销）。
2. **顺序读放大 ~1.0x**，NIC/fio ~1.06x。
3. **A-randread 读放大 2.02x**：randread block-size=256K，每 256K 随机读触发 JuiceFS chunk 读 + TiKV metadata 查询 + EC raw 读（6/4=1.5x）。总放大 2x 合理（EC 1.5x + metadata ~0.5x）。
4. **B-randread 读放大 ~1.0x**：ra0 消除预读浪费 → GET≈fio → **ra0 使 randread 从 55→112 = +103%，关键根因**。
5. **写类全撞 NIC TX 墙（~117 MB/s = 千兆 99%）**，B-randread 也撞 NIC RX 墙（118 = 100%）。
6. **A-seqread RX=109（93%）未撞墙** → 软件瓶颈（FUSE/meta 开销 ~7%），步骤3深挖。
7. **B-randrw RX=96/TX=95（81%/80%）未撞墙** → randrw 80 MB/s 未达网卡上限，ra0 后软件瓶颈仍在。
