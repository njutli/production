# Portal平台架构与子模块流程图

> 日期：2026-09-22。覆盖三个开发阶段，以已确认方案为依据。
> 第一阶段只读监控已实现；第二阶段用户与配额管理待开发；第三阶段快速部署为方案草案。本文展示的是“现有能力＋计划形成的整体架构”，不代表图中全部组件已上线。

图采用Mermaid，可在支持Mermaid的Markdown预览中查看和维护。绿色表示已实现能力，蓝色表示第二阶段规划，橙色表示第三阶段草案，灰色表示人员或外部基础设施。阶段状态同时写入标签，不仅依赖颜色。

## 1. 平台总架构

运行期管理组件集中在152，LDAP部署位置待确定；客户现场的主服务节点由第三阶段配置决定。实线表示运行期调用/访问方向，虚线表示安装交付关系；请求对应的返回未逐条画出。

```mermaid
flowchart TB
    B["浏览器：Portal ADMIN / USER"]
    subgraph M["中央管理节点：当前152"]
        P["Portal页面与API<br/>第一阶段已实现；第二阶段扩展"]
        R["只读监控模块<br/>已实现"]
        MON[("监控数据服务<br/>Prometheus，已实现")]
        S[("目录统计SQLite<br/>已实现；第二阶段调整授权范围")]
        Q["用户目录与配额控制服务<br/>quota-controller，第二阶段规划"]
        D[("存储管理SQLite<br/>第二阶段新增")]
        P --> R
        R --> MON
        P -->|只读目录快照| S
        P -->|本机Socket：授权、查询和管理| Q
        Q --> D
    end
    L[("LDAP统一业务身份<br/>第二阶段接入，位置待定")]
    subgraph C["业务客户端：157及后续获准客户端"]
        N["SSSD / NSS / PAM<br/>第二阶段接入"]
        A["训练 / 推理等业务进程"]
        J["JuiceFS业务挂载<br/>已有；第二阶段落实root-squash"]
        N -->|提供UID、GID及组信息| A
        A -->|文件读写| J
    end
    subgraph ST["存储集群：当前150～152"]
        T[("PD / TiKV<br/>JuiceFS元数据与原生配额")]
        O[("Ceph RADOS<br/>文件内容对象")]
    end
    E["集群及客户端metrics端点<br/>已接入"]
    DEP["主节点部署工具<br/>第三阶段草案"]
    B -->|HTTPS| P
    N -->|身份查询与认证| L
    Q -->|只读核对业务身份| L
    Q -->|原生元数据接口：目录核对、配额读写| T
    J -->|元数据操作| T
    J -->|数据IO| O
    MON -->|定时拉取| E
    DEP -.安装交付.-> M
    DEP -.配置接入.-> C
    DEP -.建立服务.-> ST
    classDef existing fill:#e8f5e9,stroke:#388e3c,color:#173c1e
    classDef planned fill:#e8f0fe,stroke:#4169a1,color:#183153
    classDef future fill:#fff3df,stroke:#b7791f,color:#633f0b
    classDef outside fill:#f3f4f6,stroke:#6b7280,color:#1f2937
    class P,R,MON,S,E existing
    class Q,D,L,N planned
    class DEP future
    class B,A,J,T,O outside
```

业务文件内容不经过Portal或quota-controller。Prometheus属于已有监控能力；其内部存储不在第二阶段重新设计。目录采集、独立管理挂载等细节在下图展开。

## 2. 第二阶段内部组件：服务进程、worker与数据库

`jfsweb`、`jfsquota`、`jfsstats`是拟使用的本地Linux服务账号。方框内列出进程职责；worker是quota-controller进程内的一个Go协程，没有独立PID。第一版只有一个配额变更worker，其他定时工作不计入这一数量。

```mermaid
flowchart LR
    B["浏览器"]
    subgraph WEB["Portal进程：由jfsweb运行，账号分离待实施"]
        W["登录认证 / ADMIN、USER权限<br/>API与页面"]
    end
    PC[("Portal账号配置<br/>账号ID、角色、密码哈希、认证版本")]
    subgraph CTRL["quota-controller：一个进程，由jfsquota运行，规划"]
        API["Socket接口<br/>身份登记、目录授权、预览与确认"]
        WK["1个配额变更worker<br/>串行执行、回读、恢复核对"]
        REF["用量刷新<br/>每60秒"]
        GC["清理与备份定时任务<br/>每24小时检查"]
        AD["JuiceFS原生元数据适配层"]
        WK --> AD
        REF --> AD
        API -->|身份及目录核对| AD
    end
    DB[("存储管理SQLite<br/>身份引用、目录、授权、任务及审计")]
    BK[("有限份数的一致性备份")]
    LDAP[("LDAP业务账号")]
    T[("PD / TiKV")]
    O[("Ceph")]
    subgraph STAT["统计组件：能力已有，拟由jfsstats运行"]
        COL["collector<br/>定时执行目录summary"]
        SM["JuiceFS专用统计控制挂载"]
        COL -->|原生控制请求| SM
    end
    SD[("目录统计SQLite")]
    OPS["可信运维"]
    AM["独立管理挂载<br/>用于建目录和chown，规划"]
    B --> W
    W -->|读取认证配置| PC
    W -->|Unix Socket| API
    API -->|只读查询| LDAP
    API -->|写入预览、受理状态及授权| DB
    WK -->|取任务、更新状态和审计| DB
    REF -->|更新最新观测| DB
    GC -->|清理过期记录| DB
    GC -->|一致性备份| BK
    AD --> T
    W -->|文件级只读| SD
    COL -->|原子发布统计结果| SD
    SM -->|挂载连接| T
    SM -->|Ceph连接| O
    OPS --> AM
    AM -->|目录元数据操作| T
    AM -->|挂载所需数据存储连接| O
```

Web不直接打开存储管理库，通过Socket取得授权与配额结果。quota-controller使用TiKV凭据，不需要Ceph keyring；统计挂载和管理挂载各自独立。管理挂载由可信运维控制，不启用业务挂载的root-squash。统计挂载保留原生控制接口所需能力，不用作目录交付入口。

## 3. 子模块流程：LDAP身份接入与目录交付

本期运维通过LDAP产品自己的管理工具开户；Portal只查询并登记已有业务身份。Portal登录账号仍单独管理，不自动等于同名LDAP账号。

```mermaid
flowchart TD
    A["运维通过LDAP管理工具创建用户和组<br/>例如Alice：50001 / 50001"]
    B["获准客户端接入SSSD / NSS / PAM"]
    C{"两客户端实际登录及业务进程<br/>UID、GID、组关系一致？"}
    X["修正身份或客户端配置"]
    D{"用户目录是否已存在？"}
    NEW["运维在独立管理挂载创建目录<br/>root拥有、0700，暂不交付"]
    OLD["核对已有目录、owner和数据<br/>保留原文件及权限"]
    REG["Portal ADMIN选择LDAP用户并登记目录<br/>控制器核对卷UUID、路径、inode和owner"]
    LIMIT{"此次接入需要设置初始配额？"}
    SET["执行配额预览、确认与回读流程"]
    OK{"配额已确认？"}
    WAIT["保留待交付状态并核对结果"]
    HAND["目录交付<br/>新目录由运维chown给目标LDAP用户<br/>已有目录保留已核对的权限"]
    USE["业务用户从获准客户端访问<br/>私有目录读写，共享模型按组权限只读"]
    VIEW["按需另给Portal账号授予目录查看权"]
    A --> B --> C
    C -->|否| X --> B
    C -->|是| D
    D -->|否| NEW --> REG
    D -->|是| OLD --> REG
    REG --> LIMIT
    LIMIT -->|否| HAND
    LIMIT -->|是| SET --> OK
    OK -->|否| WAIT
    OK -->|是| HAND
    HAND --> USE
    HAND --> VIEW
```

对已有且正在写入的目录，若要求首次计数和设限期间没有无配额写入窗口，由运维暂停该目录写任务。LDAP停用影响后续认证，已有进程需另行处理；撤销Portal查看权只影响网页访问。

## 4. 子模块流程：页面查询与后台采集

图中按第二阶段目标授权逻辑展示。现有监控、目录采集能力继续复用；原生配额采集和受管目录授权由新控制器提供。

```mermaid
flowchart TD
    U["浏览器请求页面数据"] --> AUTH{"Portal会话有效？"}
    AUTH -->|否| NO["拒绝请求"]
    AUTH -->|是| TYPE{"请求哪类数据？"}
    TYPE -->|集群监控| ADMIN{"是否ADMIN？"}
    ADMIN -->|否| NO
    ADMIN -->|是| MET["已有监控接口按指标白名单查询<br/>返回集群状态或带宽曲线"]
    TYPE -->|用户目录或配额| ACL["经Socket查询控制器<br/>检查当前账号与受管目录授权"]
    ACL --> GRANT{"授权有效且可核验？"}
    GRANT -->|否| NO
    GRANT -->|是| KIND{"目录明细还是配额？"}
    KIND -->|目录明细| SD[("只读目录统计SQLite<br/>本人目录向下三级、top 100及其余聚合")]
    KIND -->|配额| QD[("控制器读取存储管理SQLite<br/>原生额度与最近用量观测")]
    SD --> RESULT["返回数据和采集时间<br/>过期或缺失明确标记"]
    QD --> RESULT
    subgraph BG["后台采集，与网页请求分开"]
        C["collector每60秒执行原生summary"]
        Q["控制器每60秒读取原生quota计数"]
    end
    C -->|成功发布新代，失败保留旧代| SD
    Q -->|覆盖最新观测，失败保留成功值及时间| QD
```

页面请求不临时跑`du`或递归扫描；配额用量来自原生quota计数。目录统计无法读取0700私有目录时，显示明细不可用，不为采集放宽权限。配额和目录页面按30秒刷新、180秒标记过期；撤权按当前授权立即判断，不等待刷新周期。

## 5. 子模块流程：一次配额修改

下图中的Socket接口与worker属于同一个quota-controller进程；SQLite中的操作表承担持久化队列，不需要另部署消息队列。

```mermaid
sequenceDiagram
    actor A as Portal ADMIN
    participant P as Portal后端
    box rgb(235,242,255) quota-controller进程：jfsquota
        participant Q as Socket请求处理
        participant W as 单个配额变更worker
    end
    participant D as 存储管理SQLite
    participant T as PD/TiKV中的JuiceFS元数据
    A->>P: 输入额度和理由，申请预览
    P->>P: 校验个人ADMIN会话和请求来源
    P->>Q: 请求配额预览
    Q->>T: 经原生接口核对目录、现额和用量
    Q->>D: 核对资源/预算，保存待确认操作
    Q-->>P: 预览结果、操作编号、24小时有效期
    P-->>A: 展示变更前后值和检查结果
    A->>P: 确认该操作编号
    P->>Q: 携带当前会话身份确认
    Q->>D: 事务内核验已有编号、内容、期限和版本，受理并占预算
    Q-->>P: 返回已受理状态和操作编号
    P-->>A: 显示处理中
    W->>D: 取一个已受理任务并标记执行中
    W->>T: 复核目标/旧额度，经原生接口设置配额
    W->>T: 回读实际规则
    alt 回读与目标一致，且结果可持久化
        W->>D: 更新最新观测、任务终态及审计
    else 已调用后端但超时或结果不明确
        W->>D: 保留结果待确认及恢复信息
    end
    P->>Q: 查询操作状态
    Q->>D: 检查当前授权并读取结果
    Q-->>P: 已确认 / 明确失败 / 结果待确认
    P-->>A: 显示结果及原因
```

未知、过期或已清理编号不能创建新任务；已受理编号重试返回原结果。执行前检查未通过则记录明确失败，不调用后端。调用后审计无法落盘时，不能向页面报告成功，重启后按未决核对。各任务按单worker执行，但这不会阻止可信root从外部CLI修改配额，日常变更仍应统一经过控制器。

## 6. 子模块流程：异常任务与进程重启恢复

这是普通服务重启的恢复。恢复旧数据库备份还需执行第8节的授权及资源核对。

```mermaid
flowchart TD
    START["quota-controller启动<br/>或发现结果待确认任务"] --> LOAD["读取持久化任务及执行阶段"]
    LOAD --> TYPE{"任务属于哪种情况？"}
    TYPE -->|预览尚未确认| PRE["保留到24小时到期<br/>不执行配额修改"]
    TYPE -->|已受理且确认未调用后端| CHECK["复核当前授权、资源、额度和预算"]
    CHECK --> PASS{"仍满足执行条件？"}
    PASS -->|是| RUN["交给同一worker执行"]
    PASS -->|否| FAIL["记录明确失败及原因"]
    TYPE -->|已调用或不能排除调用| READ["回读真实配额<br/>核对目标身份和外部变更情况"]
    READ --> KNOWN{"能够确认当前配置和操作结果？"}
    KNOWN -->|是| SAVE["持久化核对结果及审计<br/>不重复执行已经完成的修改"]
    KNOWN -->|否| UNKNOWN["保持result_unknown<br/>保留预算与证据，提示管理员核对"]
    UNKNOWN --> HOLD["暂停该资源后续配额修改<br/>查询与结果核对仍可进行"]
```

只读到原来的额度，不能据此断定任务从未生效：也可能成功后又被其他管理操作改回。恢复应核对上下文，不能以此为由盲目重试。结果不明的任务不按超时自动删除或伪装为成功。

## 7. 子模块流程：过期数据清理

本流程仅清理Portal管理记录。未确认预览和已受理任务的清理条件不同；终态保留期限从实际`terminal_at`计算。

```mermaid
flowchart TD
    TIMER["每24小时维护<br/>启动时有到期维护则补一轮"] --> READY{"时间可靠、数据库可用<br/>且没有优先变更？"}
    READY -->|否| LATER["本轮跳过或提前结束<br/>记录原因，稍后再处理"]
    READY -->|是| PRE["事务内删除超过24小时的未确认预览<br/>再次核对未被确认受理"]
    PRE --> ROW["按状态及到期索引选择操作记录"]
    ROW --> STATE{"是否已确认终态？"}
    STATE -->|否| KEEP["保留任务<br/>未决超过24小时则提示"]
    STATE -->|是| AUDIT{"终态满730天<br/>且无未决引用？"}
    AUDIT -->|是| DEL["删除审计摘要及幂等记录"]
    AUDIT -->|否| DETAIL{"终态满180天？"}
    DETAIL -->|是| TRIM["清空执行详情<br/>保留审计与去重信息"]
    DETAIL -->|否| KEEP2["继续保留"]
    KEEP --> BUDGET
    DEL --> BUDGET
    TRIM --> BUDGET
    KEEP2 --> BUDGET
    BUDGET{"还有可处理批次且未达预算？"}
    BUDGET -->|是| ROW
    BUDGET -->|否| FIN["记录清理数量、积压和最近错误<br/>本轮结束"]
```

每批最多1000条，每轮最多10批或30秒。当前观测覆盖更新；在用身份、目录及授权不因年龄过期。空间或任务数量达到门槛时拒绝新建管理任务，保留未决记录。删除记录后SQLite空间可复用，文件不一定立即缩小。完整参数见[清理与备份设计](../stages/02-user-quota/features/juicefs-user-quota-management/USER-AND-QUOTA-MANAGEMENT-RESEARCH-20260914.md#1185-过期数据清理空间与备份)。

## 8. 子模块流程：有界备份与备份恢复

### 8.1 每日备份

```mermaid
flowchart TD
    A["每日备份检查"] --> B["按7天、7份、8 GiB限制轮换旧副本<br/>始终保留最后有效备份"]
    B --> C{"可容纳新备份及临时文件？"}
    C -->|否| D["跳过并告警<br/>保留最后有效副本"]
    C -->|是| E["SQLite一致性备份到本服务临时文件<br/>最多一份在建"]
    E --> F{"备份完成且校验通过？"}
    F -->|否| G["保留旧有效备份，记录失败<br/>停止的过期临时文件按规则清理"]
    F -->|是| H["原子发布新备份<br/>更新有效副本记录并完成轮换"]
```

### 8.2 恢复管理数据库

```mermaid
flowchart TD
    A["运维选择并验证一致性备份"] --> B["关闭新管理写及受保护USER查询"]
    B --> C["恢复数据库<br/>保留原事件时间"]
    C --> D["作废所有旧待确认预览<br/>恢复的查看授权默认不生效"]
    D --> E["核对未决任务，不自动重放<br/>回读全部恢复的活动资源及真实配额"]
    E --> F["更新观测与预算<br/>人工补齐备份后新增、解除纳管等差异"]
    F --> G["管理员重新确认查看授权<br/>若恢复账号配置，则使旧会话失效"]
    G --> H{"该范围核对完成？"}
    H -->|否| I["继续暂停未核实范围<br/>记录缺口与待处理项"]
    H -->|是| J["按原时间清理到期记录<br/>开放已核实范围的查询和管理"]
```

管理库备份不替代TiKV或Ceph备份。还原管理库不能将TiKV真实配额自动覆盖成备份中的旧值，也不能凭当前额度重建缺失的历史审计。

## 9. 子模块流程：第三阶段客户现场快速部署

以下为独立安装工具流程，状态为设计草案。其完整交付依赖第二阶段功能验收；运行中的Portal ADMIN会话不直接取得主机root或磁盘格式化权限。

```mermaid
flowchart TD
    A["客户运维在指定主节点启动部署工具<br/>装入固定版本部署包"] --> B["CLI或安装向导填写inventory<br/>节点、网络、磁盘、LDAP与配置"]
    B --> C["只读预检<br/>身份、依赖、设备、空间及网络"]
    C --> D{"预检通过？"}
    D -->|否| FIX["展示问题，修改配置或处理现场"] --> B
    D -->|是| PLAN["生成固定变更计划<br/>列明目标、影响及提权命令"]
    PLAN --> APPROVE["可信运维在主节点确认该计划"]
    APPROVE --> RUN["独立受控执行器执行<br/>准备主机，接入LDAP，建立TiKV与Ceph"]
    RUN --> CLIENT["format新卷<br/>先验证一个客户端再配置其余客户端"]
    CLIENT --> PORTAL["安装Portal监控和用户配额组件"]
    PORTAL --> TEST["小数据验收<br/>身份、读写、配额、监控及恢复"]
    RUN -->|失败| HOLD["保存执行进度与现场<br/>修正后核验已完成步骤再续跑"]
    CLIENT -->|失败| HOLD
    PORTAL -->|失败| HOLD
    TEST -->|失败| HOLD
    HOLD --> RESUME["从未完成步骤继续<br/>关键输入变化需重新生成和确认计划"]
    TEST -->|通过| ENDING["交付正式Portal入口和配置记录<br/>关闭安装入口及临时部署权限"]
```

安装工具退出后，Portal按运行期权限继续工作，业务客户端直接访问存储集群。主节点可能同时承担存储或LDAP角色，其整机故障影响取决于这些组件的冗余，不能等同于仅停止Portal进程。

## 10. 对应文档与维护规则

| 内容 | 依据 |
|---|---|
| 三阶段范围与状态 | [总体开发计划](../DEVELOPMENT-ROADMAP.md) |
| 已实现的监控、目录统计、刷新周期 | [第一阶段系统功能说明](../stages/01-readonly-monitoring/CURRENT-STAGE-SYSTEM-OVERVIEW-20260914.md) |
| LDAP路线A与root边界 | [LDAP实施说明](../stages/02-user-quota/features/juicefs-user-quota-management/JUICEFS-LDAP-USER-MANAGEMENT-IMPLEMENTATION-NOTES-20260922.md) |
| 第二阶段开发安排 | [第二阶段总开发计划](../stages/02-user-quota/USER-AND-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md) |
| 配额接口、任务、恢复和清理 | [配额开发计划](../stages/02-user-quota/features/juicefs-user-quota-management/JUICEFS-QUOTA-MANAGEMENT-DEVELOPMENT-PLAN-20260922.md) |
| 快速部署流程 | [第三阶段部署方案](../stages/03-deployment/CUSTOMER-DEPLOYMENT-DESIGN-20260922.md) |

具体字段、接口及保留参数以对应专题为准；变更时同步本图相关节点和连接。图中组件代表职责或数据载体，只有明确标为“进程”的边界才表示进程划分，不按每个方框新增一个服务。
