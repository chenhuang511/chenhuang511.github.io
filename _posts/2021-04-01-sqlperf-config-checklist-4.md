---
layout: post
title:  "Các cấu hình cần thiết cho SQLServer để tăng hiệu năng (P4)"
description: "Phần 4: Loại bỏ Adhoc plan trong Plan Cache"
tags: sql configuration dba
---

## 1. Plan Cache & Adhoc query

### 1.1.Plan cache

Mỗi khi thực thi một query, SQLServer sẽ sinh ra một ExecutionPlan và cache lại Plan này trong RAM, gọi là **Plan Cache**. Các plan đã cache có thể tái sử dụng để giảm chi phí cho việc compile lại ExecutionPlan khi chạy lại query.

SQLServer cũng cho phép quản lý Plan Cache bằng các DVM. Ví dụ ta có thể xem các Plan đã cache như sau:

```sql
SELECT decp.refcounts,
       decp.usecounts,
       decp.size_in_bytes,
       decp.cacheobjtype,
       decp.objtype,
       t.text,
       decp.plan_handle,
       st.last_execution_time
FROM sys.dm_exec_cached_plans AS decp
         CROSS APPLY sys.dm_exec_sql_text(decp.plan_handle) t
         INNER JOIN sys.dm_exec_query_stats st ON decp.plan_handle = st.plan_handle
WHERE t.dbid = DB_ID('EASYBOOKS')
ORDER BY decp.size_in_bytes DESC;
```

![image](/assets/images/sqlperf-1-config-9.png)

Ở trên ta đang xem toàn bộ thông tin lưu trong PlanCache của một DB cụ thể. Có một số thông tin cần quan tâm như sau:

**objtype**: 
* ```Adhoc``` là các query mà một số tham số đang được hardCoded (ex: ```...WHERE companyId = 111```)
* ```Prepared``` ngược lại là các query mà tham số được truyền vào theo kiểu param (ex: ```...WHERE companyId = @comId```).

**cacheobjtype**: ta quan tâm 2 giá trị là:
* ```Compiled Plan```: là các plan được lưu full dung lượng vào cache.
* ```Compiled Plan Stub```: là các plan chỉ lưu một phần vào cache, chứ không phải toàn bộ. Lý do có loại này là để dành cho những Plan mà SQLServer đánh giá là chỉ chạy một lần, không có khả năng tái sử dụng, vì vậy không nhất thiết phải phí RAM để lưu full plan.

### 1.2. Adhoc query (Adhoc workload)

Như đã nêu ở trên, Adhoc query là loại truy vấn mà các giá trị truyền vào cho các tham số đang được hard-coded.

Giả sử ta có 2 điều kiện tìm kiếm cho 1 query:

```sql
SELECT name,address FROM Customer WHERE id = 111;
```

```sql
SELECT name,address FROM Customer WHERE id = 112;
```

2 query trên chỉ khác nhau về giá trị của ```id```, và vì 2 giá trị này đang được hard-coded, do đó **SQLServer đang lưu 2 cached plan khác nhau**.

Điều này dẫn đến việc lãng phí bộ nhớ, và thực tế tỷ lệ sử dụng lại của các plan riêng biệt trên là rất thấp.

Thay vào đó ta có thể dùng chung 1 plan cho tất cả các query tương tự, nếu ta đổi lại thành query như sau (biến thành prepared query):

```sql
SELECT name,address FROM Customer WHERE id = @customerId;
```

Thông thường các hệ thống ORM (Entity Framework, Hibernate,...) đều giúp chúng ta tham số hóa giá trị truyền vào bằng việc bind params.

Tuy nhiên bằng 1 cách nào đó (mà không cần chỉ ra ở đây :)) Adhoc query vẫn tồn tại trong cache, và chúng ta nên định hình 1 công việc khi tối ưu hệ thống SQLServer đó là hạn chế/loại bỏ Adhoc query (Adhoc workload) trong planCache.

Ta có thể kiểm tra tài nguyên mà các Adhoc query đang chiếm trong planCache bằng query sau:

```sql
SELECT objtype,
       cacheobjtype,
       AVG(usecounts)                                   AS Avg_UseCount,
       SUM(refcounts)                                   AS AllRefObjects,
       SUM(CAST(size_in_bytes AS bigint)) / 1024 / 1024 AS Size_MB
FROM sys.dm_exec_cached_plans decp
         CROSS APPLY sys.dm_exec_sql_text(decp.plan_handle) t
WHERE t.dbid = DB_ID('EASYBOOKS134')
  AND objtype = 'Adhoc'
  AND usecounts < 5
GROUP BY objtype, cacheobjtype;
```

## 2. Tối ưu Adhoc query

### 2.1. Sử dụng cấu hình có sẵn của SQLServer

Tư tưởng đó là với các loại Adhoc query (Adhoc workload), ta có thể cấu hình để SQL Server chỉ lưu vào cache 1 phần plan (không phải full-size plan) khi các Adhoc query được thực thi lần đầu.
* Tức là lưu trong cache dưới dạng ```Compiled Plan Stub``` như trình bày ở trên.

Cấu hình trên SQLServer như sau:

```sql
EXEC sp_configure 'show advanced option', '1';
GO
RECONFIGURE
GO
EXEC sp_configure 'optimize for ad hoc workloads', 1;
GO
RECONFIGURE;
```

### 2.2. Định kỳ loại bỏ các Adhoc query

Trong maintainTasks ta có thể thêm 1 công việc đó là loại bỏ các Adhoc query, tức là xóa nó ra khỏi planCache của SQLServer.

Tùy thuộc vào từng hệ thống, ta có thể quan sát planCache và đưa ra các tiêu chí để xóa bỏ Adhoc query trong cache.

```sql
DECLARE @planHandle varbinary(64)

DECLARE db_cursor CURSOR FOR 
	SELECT DISTINCT
	 decp.plan_handle
	FROM sys.dm_exec_cached_plans AS decp
	CROSS APPLY sys.dm_exec_sql_text(decp.plan_handle) t
	WHERE t.dbid = DB_ID('EASYBOOKS134')
	AND decp.objtype = 'Adhoc' 
	AND decp.cacheobjtype = 'Compiled Plan'
	AND decp.usecounts < 5;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @planHandle;

WHILE @@FETCH_STATUS = 0  
BEGIN
	DBCC FREEPROCCACHE (@planHandle)
	FETCH NEXT FROM db_cursor INTO @planHandle 
END 

CLOSE db_cursor  
DEALLOCATE db_cursor 
```

Như ở trên, ta đang quy định các đối tượng cần bỏ là:
* Của 1 DB cụ thể là ```EASYBOOKS134```
* Kiểu lưu plan là lưu full-size (```decp.cacheobjtype = 'Compiled Plan'```)
* Số lần sử dụng < 5

Sau khi tối ưu, ta có thể kiểm tra lại thành quả bằng cách chạy lại query như ở phần 1.2:

```sql
SELECT objtype,
       cacheobjtype,
       AVG(usecounts)                                   AS Avg_UseCount,
       SUM(refcounts)                                   AS AllRefObjects,
       SUM(CAST(size_in_bytes AS bigint)) / 1024 / 1024 AS Size_MB
FROM sys.dm_exec_cached_plans decp
         CROSS APPLY sys.dm_exec_sql_text(decp.plan_handle) t
WHERE t.dbid = DB_ID('EASYBOOKS')
  AND objtype = 'Adhoc'
  AND usecounts < 5
GROUP BY objtype, cacheobjtype;
```

## 3. Tham khảo

[http://davebland.com/optimize-for-ad-hoc-workloads](http://davebland.com/optimize-for-ad-hoc-workloads)

[https://docs.microsoft.com/en-us/sql/database-engine/configure-windows/optimize-for-ad-hoc-workloads-server-configuration-option?view=sql-server-2017](https://docs.microsoft.com/en-us/sql/database-engine/configure-windows/optimize-for-ad-hoc-workloads-server-configuration-option?view=sql-server-2017)