# 内部表实现指南

本文档基于 OceanBase 内部表实现原理。

## 核心概念
### 内部表类型
内部表分为三类：

1. **实体表（System Table）**：实际存储数据的系统表，如 `__all_table`、`__all_column` 等
2. **虚拟表（Virtual Table）**：不存储数据，通过查询实体表或其他数据源动态生成
3. **系统视图（System View）**：基于虚拟表或实体表定义的视图

### Schema 拆分
**核心思想**：将原来仅在系统租户下存在的系统表拆分到普通租户下，每个租户都有对应的同名租户级系统表。

**关键特性**：

+ 所有 schema 相关的系统表都拆到租户下，且表名不变
+ 系统租户下提供 `__all_virtual_xxx` 虚拟表替代原来实体表的功能，用于获取所有租户的元信息

### Tenant ID 编解码
**问题背景**：考虑到物理恢复时租户 ID 可能会发生变化，普通租户下的系统表不能携带 tenant_id 信息。

**编解码规则**：

+ **系统租户**：系统表数据**编码**了 tenant_id（如 `table_id` 包含 tenant_id）
+ **普通租户**：系统表数据**不编码** tenant_id（如 `table_id` 是 pure_table_id，`tenant_id` 列皆为 0）

**实现方式**：

1. **SQL 读写**：
    - `tenant_id` 列：使用 `ObSchemaUtils::get_extract_tenant_id(exec_tenant_id, tenant_id)`
    - 非 `tenant_id` 列：使用 `ObSchemaUtils::get_extract_schema_id(exec_tenant_id, schema_id)`
2. **Result 解析**：
    - 使用 `XXX_WITH_TENANT_ID` 宏（如 `EXTRACT_INT_FIELD_TO_CLASS_MYSQL_WITH_TENANT_ID`）自动补上 tenant_id
3. **访问方式**：
    - 读写租户级系统表时，需要指定 `tenant_id` 访问
    - 不指定时仅读写系统租户下的同名表

## 内部表定义
### 定义文件
1. **内部表定义**：`share/inner_table/ob_inner_table_schema_def.py`
2. **生成脚本**：`share/inner_table/generate_inner_table_schema.py`
    - 运行后生成内部表的硬编码定义（C++ 头文件）

### 内部表属性
#### 1. `in_tenant_space`
+ **含义**：是否为租户级系统表
+ **取值**：
    - `true`：在普通租户下可见
    - `false`（缺省）：仅在系统租户下可见

#### 2. `is_cluster_private`
+ **前提**：`in_tenant_space = true`
+ **含义**：主备库是否需要物理同步该表数据
+ **取值**：
    - `false`（缺省）：主备库需要物理同步，该表在备库上不可写
    - `true`：此表只在 meta 租户和 sys 租户下独有

#### 3. `is_backup_private`
+ **前提**：`in_tenant_space = true`
+ **含义**：物理备份是否需要备份该表数据
+ **取值**：
    - `false`（缺省）：物理备份需要备份，物理恢复会直接恢复该租户级系统表数据
    - `true`：不需要物理备份

#### 4. `columns_with_tenant_id`
+ **前提**：`in_tenant_space = true` 且 `is_backup_private = false` 或 `is_cluster_private = false`
+ **含义**：需要编解码 tenant_id 的列名集合（不含 `tenant_id` 列本身）
+ **示例**：`['table_id', 'database_id', 'schema_id']`

#### 5. `rs_restart_related`
+ **含义**：处理 location_cache 优先级
+ **取值**：
    - `true`：RS 启动流程依赖，或 schema 刷新依赖
    - `false`（缺省）：无特殊依赖

### 如何添加内部表
添加内部表时需要回答以下问题：

#### 1. 是否普通租户可见？
+ **是**：`in_tenant_space=true`
+ **否**：`in_tenant_space=false` 或不设置

#### 2. 实体表是否需要主备库同步？
+ **是**：
    - `in_tenant_space=true`
    - `is_cluster_private=false`
    - `columns_with_tenant_id=[xxx]`
    - 普通租户下对应系统表的内容不能携带 tenant_id 信息
    - 系统租户对应系统表要携带 tenant_id 信息
+ **否**：不需要设置

#### 3. 实体表是否需要物理同步恢复？
+ **是**：
    - `in_tenant_space=true`
    - `is_backup_private=false`
    - `columns_with_tenant_id=[xxx]`
    - 普通租户下对应系统表的内容不能携带 tenant_id 信息
    - 系统租户对应系统表要携带 tenant_id 信息
+ **否**：不需要设置

**注意**：一般来说，`is_cluster_private=false` 的表是 `is_backup_private=false` 的表的子集。

#### 4. 相关租户级系统表主备同步/物理备份恢复行为是否与 Oracle 兼容？
需要根据具体需求判断。

#### 5. 相关租户级系统表读写逻辑是否正确地过滤了 tenant_id？
需要确保使用 `ObSchemaUtils::get_extract_xxx_id()` 函数。

### 内部表定义格式
```python
# 实体表示例
('__all_table', {
    'table_id': OB_ALL_TABLE_TID,
    'columns': [
        ('tenant_id', 'uint64_t', 'NOT NULL', '0'),
        ('table_id', 'uint64_t', 'NOT NULL', '0'),
        ('table_name', 'varchar(128)', 'NOT NULL', ''),
        # ...
    ],
    'primary_key': ['tenant_id', 'table_id'],
    'in_tenant_space': True,
    'is_cluster_private': False,
    'is_backup_private': False,
    'columns_with_tenant_id': ['table_id', 'database_id'],
    'rs_restart_related': True,
})
```

## 虚拟表定义
### 虚拟表属性
#### 1. `in_tenant_space`
+ **含义**：是否为租户级虚拟表
+ **取值**：
    - `true`：租户级虚拟表，租户下可见（MySQL 租户看不到 Oracle 相关的虚拟表，Oracle 租户看不到非 Oracle 相关的虚拟表）
    - `false`（缺省）：仅系统租户下可见

#### 2. `vtable_route_policy`（4.0 之后版本）
+ **含义**：虚拟表路由方式
+ **取值**：
    - `local`（缺省）：虚拟表仅在本地执行
    - `only_rs`：虚拟表需要路由到 RS 上执行
    - `distributed`：虚拟表需要分布式执行，此时要求列定义含 `['svr_ip', 'svr_port']`
        * 系统租户下执行：路由到集群所有机器上执行
        * 普通租户下执行：仅在有租户资源的机器上执行

### 虚拟表实现方式
#### 1. `gen_iterate_virtual_table_def`
+ **用途**：系统租户下虚拟表，依赖的实体表是租户级系统表，且 `tenant_id` 为主键列第一列
+ **行为**：
    - 不指定 `tenant_id` 查询时：返回所有租户对应实体表的数据
    - 指定 `tenant_id` 时：返回特定租户实体表数据
+ **参数**：
    - `real_tenant_id`：
        * `true`：依赖的实体表 `is_cluster_private/is_backup_private` 为 `true`，并且基表有 `tenant_id` 列
        * `false`：其他情况

#### 2. `gen_iterate_private_virtual_table_def`
+ **用途**：4.0 由于私有表仅存在于 sys/meta 租户，需要在系统租户下定义虚拟表迭代所有 sys/meta 租户的实体表内容
+ **参数**：
    - `meta_record_in_sys`：
        * `false`（缺省）：meta 租户元信息记录在 meta 租户下
        * `true`：meta 租户元信息记录在 sys 租户下

#### 3. `gen_agent_virtual_table_def`
+ **用途**：一般 agent 表定义，负责完成 MySQL 虚拟表/实体表的数据类型转换
+ **限制**：依赖的实体表不能是租户级系统表（否则可能会因为实体表部分列不含 tenant_id 导致查询不符合预期）

#### 4. `gen_oracle_mapping_virtual_table_def`
+ **用途**：依赖的表应该是 MySQL 虚拟表，无需定义 agent 表，直接在 MySQL 虚拟表实现上做数据类型转换

#### 5. `gen_oracle_mapping_real_virtual_table_def`
+ **用途**：依赖的表应该是租户级实体表，自动处理数据类型转换，实体表列是否自动编解码 tenant_id 的问题

### 虚拟表实现注意事项
1. **主键列排序**：虚拟表在单机的实现需要保证按主键列升序输出（优化器依赖该特性），否则在某些查询条件下会产生正确性问题。
2. **主键/索引列**：虚拟表主键/索引列一般用于提取 `key_range`，优化虚拟表特定查询条件的性能。如果没有虚拟表性能优化的需求（扫全表快，或一般都是扫全表），一般不定义主键/索引。
3. **租户级虚拟表实现**：原则上要求系统租户能看到集群所有租户的相关数据，普通租户仅能看到本租户的相关数据。

## 内部表修改原则
### 基本规则
1. **Table ID**：
    - 系统表、虚拟表（MySQL、Oracle）、视图（MySQL、Oracle）都有各自的 table_id 定义范围
    - Table ID 单调递增
    - 系统表只增不删
    - 虚拟表允许删但对应 table_id 不可重用，需要注释标明该 table_id 已被废弃
2. **列修改**：
    - **系统表**：列只能在末尾添加，只增不删
    - **虚拟表**：列在尾部追加，并且需要补上虚拟表实现，不然访问会报错
    - **系统表加列**：要么是 "nullable"，要么是 "非 nullable + 定义缺省值"
3. **索引**：
    - 系统表和虚拟表新增索引都需要特殊支持，一般不支持
4. **虚拟表/视图**：
    - 可修改实现，但不能修改虚拟表/视图名
    - 修改虚拟表/视图名相当于新建虚拟表/视图，保证 table_id 不重用
5. **实体表与虚拟表**：
    - 一般定义实体表，也需要定义对应的虚拟表及视图

### 列定义格式
```python
('column_name', 'column_type', 'nullable', 'default_value')
```

示例：

```python
('tenant_id', 'uint64_t', 'NOT NULL', '0'),
('table_id', 'uint64_t', 'NOT NULL', '0'),
('table_name', 'varchar(128)', 'NOT NULL', ''),
('create_time', 'int64_t', 'NULL', '0'),
```

## 内部表读写实现
### 系统租户读写
系统租户可以直接访问实体表，数据包含 tenant_id 信息：

```cpp
// 示例：查询所有租户的表信息
SELECT * FROM __all_table WHERE table_name = 'test_table';
// 返回结果中 table_id 包含 tenant_id 信息
```

### 普通租户读写
普通租户访问同名系统表，数据不包含 tenant_id 信息：

```cpp
// 示例：查询本租户的表信息
SELECT * FROM __all_table WHERE table_name = 'test_table';
// 返回结果中 table_id 是 pure_table_id，tenant_id 列为 0
```

### 系统租户查看所有租户数据
系统租户通过虚拟表查看所有租户的数据：

```cpp
// 示例：通过虚拟表查询所有租户的表信息
SELECT * FROM __all_virtual_table WHERE table_name = 'test_table';
// 返回所有租户的数据
```

### 代码实现示例
#### 1. SQL 查询（需要编解码 tenant_id）
```cpp
// 查询特定租户的表信息
int64_t exec_tenant_id = OB_SYS_TENANT_ID;
uint64_t tenant_id = 1001;
uint64_t table_id = combine_id(tenant_id, pure_table_id);

// 在 SQL 中使用 ObSchemaUtils::get_extract_xxx_id()
// SELECT * FROM __all_table 
// WHERE tenant_id = ObSchemaUtils::get_extract_tenant_id(exec_tenant_id, tenant_id)
//   AND table_id = ObSchemaUtils::get_extract_schema_id(exec_tenant_id, table_id);
```

#### 2. Result 解析（需要补上 tenant_id）
```cpp
// 使用宏自动补上 tenant_id
EXTRACT_INT_FIELD_TO_CLASS_MYSQL_WITH_TENANT_ID(
    result, "table_id", table_schema.table_id_, uint64_t);
```

#### 3. 指定 tenant_id 访问租户级系统表
```cpp
// 使用 inner_sql 读写租户级系统表需要指定 tenant_id
int64_t target_tenant_id = 1001;
// 明确操作的实体表的名字空间
// 不指定的情况下表示访问系统租户
```

## 内部表访问方式
### 1. 系统租户访问
+ **实体表**：直接访问 `__all_xxx`，数据包含 tenant_id 信息
+ **虚拟表**：访问 `__all_virtual_xxx`，可以查看所有租户的数据

### 2. 普通租户访问
+ **实体表**：访问同名 `__all_xxx`，数据不包含 tenant_id 信息（tenant_id 列皆为 0）
+ **虚拟表**：访问同名 `__all_virtual_xxx`，仅能看到本租户的数据

### 3. Change Tenant 命令
外部可通过 `change tenant` 命令操作租户级系统表：

```sql
-- 命令格式
ALTER SYSTEM CHANGE TENANT tenant_id = 1001;
-- 或
ALTER SYSTEM CHANGE TENANT tenant_name = 'test_tenant';

-- 限制：
-- 1. 仅支持 observer 直连的方式使用（不能走 proxy）
-- 2. 需要以系统租户的身份登录
-- 3. 不支持事务
```

## 实现流程
### 1. 定义内部表
在 `share/inner_table/ob_inner_table_schema_def.py` 中定义：

```python
# 实体表定义
('__all_new_table', {
    'table_id': OB_ALL_NEW_TABLE_TID,  # 需要在对应区域末尾通过注释占位
    'columns': [...],
    'primary_key': [...],
    'in_tenant_space': True,
    'is_cluster_private': False,
    'is_backup_private': False,
    'columns_with_tenant_id': ['table_id'],
})

# 虚拟表定义
('__all_virtual_new_table', {
    'table_id': OB_ALL_VIRTUAL_NEW_TABLE_TID,
    'columns': [...],
    'in_tenant_space': True,
    'vtable_route_policy': 'local',  # 或 'only_rs' 或 'distributed'
})
```

![](https://intranetproxy.alipay.com/skylark/lark/0/2025/png/188756788/1765778851213-9472d0cc-9847-45c4-8cde-a551c8e39e69.png)

### 2. 生成硬编码定义
运行生成脚本：

```bash
cd share/inner_table
python generate_inner_table_schema.py
```

这会生成 C++ 头文件，包含 table_id、列定义等硬编码信息。

### 3. 实现虚拟表逻辑
在对应的虚拟表实现文件中实现查询逻辑：

```cpp
// 示例：实现 __all_virtual_new_table 的查询逻辑
int ObVirtualNewTable::inner_get_next_row(ObNewRow *&row)
{
    // 1. 根据 tenant_id 过滤（如果是租户级虚拟表）
    // 2. 查询对应的实体表或数据源
    // 3. 编解码 tenant_id（如果需要）
    // 4. 返回结果
}
```

### 4. 实现读写逻辑
在需要读写内部表的代码中：

```cpp
// 1. 使用 ObSchemaUtils::get_extract_xxx_id() 处理 tenant_id
// 2. 指定 tenant_id 访问租户级系统表
// 3. 使用 XXX_WITH_TENANT_ID 宏解析结果
```

## 系统变量修改
1. 修改ob_system_variable_init.json，并<font style="color:#F5222D;">执行./gen_ob_sys_variables.py</font>即可，无需额外修改升级脚本。
2. 系统变量id应该保证单调递增
3. 无法废弃系统变量（只增不删）

## 注意事项
### 1. 不要假设升级时候禁 DDL
在实现内部表相关功能时，不要假设升级时候禁 DDL。系统表可能在任何时候被修改。

### 2. 版本号异步生效
版本号在集群范围内是异步生效的。若要基于版本号做防御，切记收发端都加防御（典型的是 DDL 执行过程中，Resolver 和 RS 都要做防御）。

### 3. 列 Column ID 修正
由于历史上升级脚本定义错误，对于升级上来的集群，其 `__all_table/__all_table_history` 两张表列的 column_id 可能与同版本 bootstrap 起来的不一样。

**解决方案**：

+ 使用 `ObSchemaUtils::get_all_table_name()` / `ObSchemaUtils::get_all_table_history_name()` 获取对应表名
+ 外部应该访问 `__all_virtual_table/__all_virtual_table_history` 获取集群 table 的 schema 信息

### 4. Oracle 虚拟表
由于数据格式的问题，Oracle 租户只能访问 SYS 下的 Oracle 虚拟表/系统视图。

## 测试验证
### 测试用例
内部表修改涉及的测试用例：

**Oracle**：

+ `tools/deploy/mysql_test/test_suite/inner_table/r/oracle/desc_sys_views_in_oracle.result`：Oracle 视图

**MySQL**：

+ `tools/deploy/mysql_test/test_suite/inner_table/r/mysql/show_sys_tables_in_sys.result`：系统表
+ `tools/deploy/mysql_test/test_suite/inner_table/r/mysql/inner_table_overall.result`：添加内部表
+ `tools/deploy/mysql_test/test_suite/inner_table/r/mysql/desc_virtual_table_in_sys.result`：系统租户虚拟表
+ `tools/deploy/mysql_test/test_suite/inner_table/r/mysql/desc_virtual_table_in_mysql.result`：MySQL 租户虚拟表
+ `tools/deploy/mysql_test/test_suite/inner_table/r/mysql/desc_sys_views_in_sys.result`：系统租户视图
+ `tools/deploy/mysql_test/test_suite/inner_table/r/mysql/desc_sys_views_in_mysql.result`：MySQL 租户视图

### 运行测试
```bash
ob farm mysqltest -bc '分支名,commitID' \
    --observer 本地编译的二进制路径 \
    test-set=inner_table.desc_sys_views_in_oracle,\
            inner_table.show_sys_tables_in_sys,\
            inner_table.inner_table_overall,\
            inner_table.desc_virtual_table_in_sys,\
            inner_table.desc_virtual_table_in_mysql,\
            inner_table.desc_sys_views_in_sys,\
            inner_table.desc_sys_views_in_mysql,\
            information_schema
```

## 总结
### 核心要点
1. **Schema 拆分**：系统表拆分到租户下，系统租户通过虚拟表查看所有租户数据
2. **Tenant ID 编解码**：系统租户编码 tenant_id，普通租户不编码
3. **内部表属性**：`in_tenant_space`、`is_cluster_private`、`is_backup_private`、`columns_with_tenant_id`
4. **虚拟表实现**：根据需求选择合适的实现方式（`gen_iterate_virtual_table_def` 等）
5. **读写逻辑**：使用 `ObSchemaUtils::get_extract_xxx_id()` 和 `XXX_WITH_TENANT_ID` 宏

### 实现流程
1. 在 `ob_inner_table_schema_def.py` 中定义内部表
2. 运行 `generate_inner_table_schema.py` 生成硬编码定义
3. 实现虚拟表查询逻辑（如果需要）
4. 实现读写代码，正确处理 tenant_id 编解码
5. 运行测试用例验证

### 数据库大赛注意事项
1. **不需要考虑升级兼容性**：不需要实现升级脚本、barrier 版本等复杂逻辑
2. **可以简化主备同步**：如果不需要主备同步功能，可以简化 `is_cluster_private` 相关逻辑
3. **可以简化物理备份恢复**：如果不需要物理备份恢复功能，可以简化 `is_backup_private` 相关逻辑
4. **重点关注核心功能**：租户隔离、tenant_id 编解码、虚拟表实现等核心功能

