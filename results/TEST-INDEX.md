# 测试项与结果目录对应关系

> 更新时间：2026-06-28

| # | 测试项 | 结果目录 | 状态 |
|---|--------|----------|------|
| 1 | 冷态全量 bs=256K / block-size=256K / cache=0 R1 | results/full-bs256k-cold-r1-20260626-200742 | ✅ 完成 |
| 2 | 冷态全量 bs=256K / block-size=256K / cache=0 R2 | results/full-bs256k-cold-r2-20260626-224117 | ✅ 完成 |
| 3 | 暖态全量 bs=256K / block-size=256K / cache=100G R1 | results/full-bs256k-warm-r1-20260627-014343 | ✅ 完成 |
| 4 | 暖态全量 bs=256K / block-size=256K / cache=100G R2 | results/full-bs256k-warm-r2-20260627-053524 | ✅ 完成 |
| 5 | 冷态 RGW + fio bs=4M / block-size=256K / cache=0（mu/ra 默认） | results/rgw-4m-bs256k-default-mu | ✅ 完成 |
| 6 | 冷态直连 + fio bs=4M / block-size=256K / cache=0（mu/ra 默认） | results/norgw-4m-bs256k-default-mu | ✅ 完成 |
| 7 | 冷态顺序读写 fio bs=4M / block-size=4M / cache=0 | results/seq-4m-bs4m-cold-20260627-160936 | ✅ 完成 |
| 8 | 暖态顺序读写 fio bs=4M / block-size=4M / cache=100G | results/seq-4m-bs4m-warm-20260627-193050 | ✅ 完成 |
| 9 | 暖态全量 bs=256K / block-size=256K / cache=100G / ra=0 R1 | results/full-bs256k-warm-ra0-r1-20260627-204424 | ✅ 完成 |
| 10 | 暖态全量 bs=256K / block-size=256K / cache=100G / ra=0 R2 | results/full-bs256k-warm-ra0-r2-20260627-230543 | ✅ 完成 |
| 11 | 暖态全量 bs=256K / block-size=256K / cache=100G / mu=150 R1 | results/full-bs256k-warm-mu150-r1-20260628-011849 | ✅ 完成 |
| 12 | 暖态全量 bs=256K / block-size=256K / cache=100G / mu=150 R2 | results/full-bs256k-warm-mu150-r2-20260628-062738 | ✅ 完成 |
| 13 | 新建 results-table-20260627.md 汇总本次全部测试结果 | — | 🔄 进行中 |
| 14 | 更新 TEST-INDEX.md | — | ✅ 完成 |

## 备注

- #5 旧数据（mu=150）保留在 results/rgw-4m-bs256k-20260626，新数据（mu/ra 默认）在 results/rgw-4m-bs256k-default-mu
- #6 旧数据（mu=150）保留在 results/norgw-4m-bs256k-20260626，新数据（mu/ra 默认）在 results/norgw-4m-bs256k-default-mu
- #8 首次暖态测试因集群残留 slow op 告警被 abort，清除告警后重跑成功，有效结果目录为带 193050 时间戳的
- #9 首次挂载参数引号问题失败（204046 目录可忽略），有效结果为 204424 目录
