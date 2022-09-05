---
layout: post
title:  "Read-Only Routing"
description: "Kỹ thuật điều hướng giúp phân tải Read-only connection cho SQLServer"
tags: sql read-only dba
---

> Thông thường ở DB, 80% query là READ và 20% query là WRITE. Với kỹ thuật Read-Only Routing giúp phân tải các READ query, từ đó có thể nâng cao hiệu năng của DB.

## 1. Thông thường ở AAG...

![image](/assets/images/sqlperf-10-1.png)

Các node secondary trong cụm AAG như NODE 2, NODE 3 chỉ đóng vai trò khắc phục thảm họa. AAG có thể đưa một trong các node này thành PRIMARY trong trường hợp có sự cố ở NODE 1. 

Thực tế không hề có query nào được thực hiện trên NODE 2, NODE 3, kể cả các READ-ONLY query. 

* Để nâng cao hiệu năng, hạn chế LOCK, ta có thể điều hướng các READ-ONLY query đến NODE 2 và NODE 3.

## 2. Khi cấu hình Read-Only Routing...

![image](/assets/images/sqlperf-10-2.png)

#### Với Read-Write client

(1) Client tạo kết nối Read-Write đến AAG với Datasource: ```...Server=AAG-Listener;ApplicationIntent=ReadWrite...``` hoặc không cần khai báo ```ApplicationIntent```

(2) AAG Listener response với NODE 1 Address

(3) Client kết nối đến NODE 1 (PRIMARY)

#### Với Read-Only client

(1) Client tạo kết nối Read-Write đến AAG với Datasource: ```...Server=AAG-Listener;ApplicationIntent=ReadOnly...``` (ApplicationIntent là bắt buộc)

(2) AAG Listener response với NODE 2 Address

(3) Client kết nối đến NODE 2 (SECONDARY)

## 3. Các tính năng của kỹ thuật Read-Only routing

#### Cân bằng tải các read-only query giữa nhiều node

Với trường hợp AAG có nhiều node secondary (nhiều slave), ta có thể cấu hình để cân bằng tải các read-only query giữa các slave này.

Như trong ví dụ trên, ta có thể cấu hình để cân bằng tải giữa NODE 2 và NODE 3.

#### Ưu tiên điều hướng đến các node nhất định

Ở trong một vài trường hợp, ví dụ NODE 2 và NODE 1 nằm cùng Datacenter, nhưng NODE 3 lại nằm ở Datacenter khác. Khi đó việc đồng bộ dữ liệu giữa NODE 1 và NODE 3 sẽ có 1 độ trễ nhất định, hơn so với giữa NODE 1 và NODE 2.

Khi đó ta có thể cấu hình để điều hướng ưu tiên các read-only query đến với NODE 2, sau đó mới đến NODE 3 (trong trường hợp NODE 2 không sẵn sàng)

#### Hỗ trợ điều hướng khi vai trò các node thay đổi

Trong trường hợp có sự cố xảy ra, NODE 1 không còn là PRIMARY nữa, mà khi đó giả sử NODE 2 sẽ được AAG đưa lên làm PRIMARY, kỹ thuật read-only routing vẫn đảm bảo điều hướng các read-only đến NODE 3 hoặc NODE 1 (nếu NODE 1 join trở lại với vai trò Secondary).

#### Tự động điều hướng lại nếu có sự cố ở 1 node

![image](/assets/images/sqlperf-10-3.png)

Ví dụ khi read-only query được điều hướng đến NODE 2, tuy nhiên việc kết nối giữa client đến NODE 2 có lỗi xảy ra, hệ thống sẽ tự động điều hướng lại kết nối của client đến NODE 3.

#### Trong suốt với Client

Client khi tạo kết nối read-only đến AAG, hoàn toàn không cần quan tâm vai trò các NODE trong AAG tại thời điểm kết nối. Client chỉ cần kết nối đến địa chỉ LISTENER của AAG, và khai báo kết nối là Read-only.

![image](/assets/images/sqlperf-10-4.png)

Như ví dụ, datasource **datasource** là Read-Write, và datasource **datasourceReport** (ở dưới) là Read-Only, cả 2 đều chỉ kết nối đến địa chỉ Listener **10.100.122.18:1433**, chỉ khác nhau **ApplicationIntent**.

## 3. Ví dụ cấu hình Read-Only Routing

```sql
--Cho phép tạo kết nối Read-Only đến NODE 1 có server_name=DC_KTSQL_SRV1
ALTER AVAILABILITY GROUP [AAG-EB]
    MODIFY REPLICA ON
    N'DC_KTSQL_SRV1' WITH
        (SECONDARY_ROLE (ALLOW_CONNECTIONS = READ_ONLY));
--Khai báo URL để Listener trả về Client, khi NODE 1 có vai trò SECONDARY
ALTER AVAILABILITY GROUP [AAG-EB]
    MODIFY REPLICA ON
    N'DC_KTSQL_SRV1' WITH
        (SECONDARY_ROLE (READ_ONLY_ROUTING_URL = N'TCP://10.100.122.8:1433'));

--Cho phép tạo kết nối Read-Only đến NODE 2 có server_name=DC_KTSQL_SRV2
ALTER AVAILABILITY GROUP [AAG-EB]
    MODIFY REPLICA ON
    N'DC_KTSQL_SRV2' WITH
        (SECONDARY_ROLE (ALLOW_CONNECTIONS = READ_ONLY));
--Khai báo URL để Listener trả về Client, khi NODE 2 có vai trò SECONDARY
ALTER AVAILABILITY GROUP [AAG-EB]
    MODIFY REPLICA ON
    N'DC_KTSQL_SRV2' WITH
        (SECONDARY_ROLE (READ_ONLY_ROUTING_URL = N'TCP://10.100.122.9:1433'));

--Nếu NODE 1 là PRIMARY, thì cân bằng tải kết nối read-only giữa 2 node
ALTER AVAILABILITY GROUP [AAG-EB]
    MODIFY REPLICA ON
    N'DC_KTSQL_SRV1' WITH
        (PRIMARY_ROLE (READ_ONLY_ROUTING_LIST = ('DC_KTSQL_SRV2','DC_KTSQL_SRV1')));

--Nếu NODE 2 là PRIMARY, --Nếu NODE 1 là PRIMARY, thì cân bằng tải kết nối read-only giữa 2 node
ALTER AVAILABILITY GROUP [AAG-EB]
    MODIFY REPLICA ON
    N'DC_KTSQL_SRV2' WITH
        (PRIMARY_ROLE (READ_ONLY_ROUTING_LIST = ('DC_KTSQL_SRV1','DC_KTSQL_SRV2')));
GO 
```

Trong đó:
* ``AAG-EB``: Tên của cluster AAG
* ``DC_KTSQL_SRV1``: server name (computer name) của Node 1, ``DC_KTSQL_SRV2`` - server name (computer name) của Node 2
* ```READ_ONLY_ROUTING_URL = N'TCP://10.100.122.9:1433'```: là địa chỉ để Listener điều hướng kết nối read-only đến Node.

#### READ_ONLY_ROUTING_LIST

Như ví dụ trên ta định nghĩa Routing list, cho phép cân bằng tải kết nối read-only giữa 2 node bằng cách:

```sql
READ_ONLY_ROUTING_LIST = ('DC_KTSQL_SRV1','DC_KTSQL_SRV2')
```

Các server instance bên trong dấu ngoặc đơn (), được cân bẳng tải.

```sql
READ_ONLY_ROUTING_LIST = (('Server1','Server2'), 'Server3', 'Server4')  
```

Với ví dụ trên:
* Routing list cân bằng tải giữa 2 node read-only là ``Server1`` và ``Server2``
* Trong trường hợp 2 server 1 và 2 không thể kết nối, routing list sẽ điều hướng read-only đến ``Server3`` trước, nếu không được mới đến ``Server4``

### Kiểm tra cấu hình Read-Only Routing bằng query

```sql
select
 ag.name as "Availability Group"
 , ar.replica_server_name as "Source Replica"
 , ar2.replica_server_name as "Read-Only Destination"
 , rl.routing_priority as "Routing Priority"
 , ar.secondary_role_allow_connections_desc as "Allowed Secondary Role"
 , ar2.read_only_routing_url as "Read-Only Routing Url"
from sys.availability_read_only_routing_lists rl
 inner join sys.availability_replicas ar on rl.replica_id = ar.replica_id
 inner join sys.availability_replicas ar2 on rl.read_only_replica_id = ar2.replica_id
 inner join sys.availability_groups ag on ar.group_id = ag.group_id
order by ag.name, ar.replica_server_name, rl.routing_priority;
```

![image](/assets/images/sqlperf-10-6.png)

## 4. Tạo kết nối Read-Only từ Client

* Kết nối đến địa chỉ của Listener
* Khai báo ``ApplicationIntent`` là ``ReadOnly`` ở datasource.

#### Java

Chỉ support với JDBC driver ``mssql-jdbc`` version thấp nhất là **6.0**

Ví dụ khai báo datasource ở **Java Spring**:

```java
# connection string in config file
jdbc:sqlserver://10.100.122.18:1433;database=EB88;ApplicationIntent=READONLY
```

```java
    @Bean(destroyMethod = "close", name = "dataSourceReport")
    @ConditionalOnExpression("#{!environment.acceptsProfiles('cloud') && !environment.acceptsProfiles('heroku')}")
    public DataSource dataSourceReport(DataSourceProperties dataSourceProperties, JHipsterProperties jHipsterProperties) {
        config.setDataSourceClassName(env.getProperty("spring.datasourceReport.driverClassName", String.class));
        config.addDataSourceProperty("url", env.getProperty("spring.datasourceReport.url", String.class));
        config.addDataSourceProperty("user", env.getProperty("spring.datasourceReport.username", String.class));
        config.addDataSourceProperty("password", env.getProperty("spring.datasourceReport.password", String.class));
        config.setJdbcUrl(env.getProperty("spring.datasourceReport.url", String.class));
        config.setAutoCommit(env.getProperty("spring.datasourceReport.hikari.auto-commit", Boolean.class));
        config.setAllowPoolSuspension(false);
        config.setPoolName(env.getProperty("spring.datasourceReport.poolName"));
        config.setLeakDetectionThreshold(0);

        return new HikariDataSource(config);
    }

    @Bean(name = "reportEntityManagerFactory")
    public LocalContainerEntityManagerFactoryBean entityManagerFactory(
        EntityManagerFactoryBuilder builder,
        @Qualifier("dataSourceReport") DataSource dataSource
    ) {
        return builder.dataSource(dataSource)
                .packages("com.softdreams.ebwebtt88.domain")
                .persistenceUnit("reportPersistenUnit").build();
    }
```

```java
public class SABillRepositoryImpl implements SABillRepositoryCustom {

    @Autowired
    @PersistenceContext(unitName = "entityManagerFactory")
    private EntityManager entityManager;

    @Autowired
    @PersistenceContext(unitName = "reportEntityManagerFactory")
    EntityManager entityManagerReadOnly;
    
    ...
    
    Query querySum = entityManagerReadOnly.createNativeQuery("select sum(a.TotalAll) " + sqlWhere.toString());
```
#### .NET

Với **.NET** thì đương nhiên được hỗ trợ một cách native. Sử dụng connection string như sau:

```c#
Server=tcp:10.100.122.18,1433;Database=EB88;IApplicationIntent=ReadOnly
```

#### SSMS

Hoặc đơn giản ta có thể test với **SSMS** với cấu hình như sau:

![image](/assets/images/sqlperf-10-5.png)

## 5. Nhược điểm khi đọc dữ liệu từ Secondary Node

Đó là luôn có một độ trễ nhất định trong việc đồng bộ dữ liệu giữa Node Primary với các Node Secondary, do đó, đôi khi **dữ liệu đọc từ Secondary node không phải là dữ liệu mới nhất**.

## 6. Tham khảo

[Microsoft doc](https://docs.microsoft.com/en-us/sql/database-engine/availability-groups/windows/configure-read-only-routing-for-an-availability-group-sql-server?view=sql-server-2017)

[https://dba2o.wordpress.com/2019/03/25/sql-server-read-only-routing/](https://dba2o.wordpress.com/2019/03/25/sql-server-read-only-routing/)

[https://sqlchitchat.com/admin/hadr/read-only-routing-in-sql-server/](https://sqlchitchat.com/admin/hadr/read-only-routing-in-sql-server/)