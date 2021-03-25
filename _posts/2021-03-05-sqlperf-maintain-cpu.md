---
layout: post
title:  "Các công việc maintain Database thường xuyên - Phần 1: CPU"
description: "Phần 1: Tìm query gây cao tải CPU"
tags: sql maintain cpu dba

---

## 1. Liệt kê các query/session đang tốn CPU

Sử dụng **DVM** built-in của SQLServer:

```sql
SELECT s2.text,
       session_id,
       start_time,
       status,
       cpu_time,
       blocking_session_id,
       wait_type,
       wait_time,
       wait_resource,
       open_transaction_count
FROM sys.dm_exec_requests a
         CROSS APPLY sys.dm_exec_sql_text(a.sql_handle) AS s2
WHERE status IN ('Suspended', 'Running', 'Runnable')
 --   AND cpu_time > 100000
ORDER BY cpu_time DESC
```

![image](/assets/images/sqlperf-3-maintain-cpu-1.png)

* Status chỉ cần là 1 trong 3 trạng thái ```Suspended``` ```Running``` ```Runnable```. Đặc biệt ta không quan tâm đến trạng thái ```Background```, đây là trạng thái dành cho các Background Task của SQLServer.
* Wait_time: là thời gian query/transaction phải đợi để có thể lấy resource đang request.
* Cpu_time: là thời gian xử lý của CPU (theo millisecond) cho query/transaction.

Ở đây ta quan tâm chủ yếu đến ```cpu_time``` và ```wait_time```. 2 yếu tố này thể hiện thời gian CPU phải xử lý request, và các số này cao và đang tăng giữa các lần exec query trên thể hiện session/query/transaction tương ứng đang gây cao tải ở CPU.

Như trong ví dụ trên, ta có thể thấy các **session 114, 116, 132, 180, 184** đang có ```cpu_time``` tương ứng rất cao. Đây là các session đang gây cao tải trên CPU. Dựa vào queryText ta có thể tìm cách để xử lý vấn đề.

### Kill nóng các session

Trong trường hợp CPU đang quá cao, ảnh hưởng đến ứng dụng không thể phục vụ người dùng; việc tìm nguyên nhân và sửa lỗi sẽ mất thời gian, khi đó có thể ```KILL``` nóng các session đang gây cao tải.

```sql
KILL <session_id>
```

Khi có quá nhiều session cao tải đang xuất phát từ cùng 1 query (do chức năng cung cấp trên ứng dụng đang có vấn đề), có thể ước lượng và **KILL đồng thời nhiều session**.

```sql
declare @sessionId INT,
		@kill nvarchar(20)= 'kill ',
        @sqln nvarchar (255)

DECLARE db_cursor CURSOR FOR 
	SELECT session_id
	FROM sys.dm_exec_requests a
	CROSS APPLY sys.dm_exec_sql_text(a.sql_handle) AS s2  
	WHERE status IN ('Suspended','Running','Runnable')
	and text like '(@P0 varbinary(8000),@P1 int,@P2 varbinary(8000),@P3 nvarchar(4000)%'
	and cpu_time > 200000
	order by cpu_time desc

OPEN db_cursor  
FETCH NEXT FROM db_cursor INTO @sessionId

WHILE @@FETCH_STATUS = 0  
BEGIN
	SET @sqln = @kill + cast(@sessionId as nvarchar(10))
    select @sqln
    EXECUTE sp_executesql @sqln
	FETCH NEXT FROM db_cursor INTO @sessionId 
END 

CLOSE db_cursor  
DEALLOCATE db_cursor 
```

Như trong ví dụ trên, thực hiện KILL các session theo các điều kiện:
* query_text là query có prefix ```(@P0 varbinary(8000),@P1 int,@P2 varbinary(8000),@P3 nvarchar(4000)```
* thời gian xử lý ở CPU > 20000 milliseconds

## 2. sp_who

SQLServer cung cấp thêm một Procedure cho phép quản lý thêm các thông tin về Client so với DMV ở trên.

```sql
exec sp_who2
```

![image](/assets/images/sqlperf-3-maintain-cpu-2.png)

Tuy nhiên tham số truyền vào cho procedure ```sp_who``` chỉ có ```loginame```, như vậy không đủ để ta lọc các điều kiện.

Vì vậy cần custom một chút ở đây:

```sql
CREATE TABLE #sp_who2 (SPID INT,Status VARCHAR(255),
      Login  VARCHAR(255),HostName  VARCHAR(255),
      BlkBy  VARCHAR(255),DBName  VARCHAR(255),
      Command VARCHAR(255),CPUTime INT,
      DiskIO INT,LastBatch VARCHAR(255),
      ProgramName VARCHAR(255),SPID2 INT,
      REQUESTID INT)
INSERT INTO #sp_who2 EXEC sp_who2
SELECT      *
FROM        #sp_who2
WHERE       DBName <> 'master'
	AND CPUTime > 100000
ORDER BY    CPUTime DESC
 
DROP TABLE #sp_who2
```

Bằng cách insert kết quả của ```sp_who``` vào bảng tạm, ta có thể thực hiện lọc hay sắp xếp các thông tin mong muốn.

![image](/assets/images/sqlperf-3-maintain-cpu-3.png)

* Với ```SPID2``` chính là ```session_id``` ta có thể kết hợp với DMV ở trên để tìm ra query tương ứng.

```sql
...WHERE session_id = <SPID2>
```

> Công việc còn lại vẫn là xử lý query gây cao tải ở CPU
>

## 3. Tips

Thay vì remote vào DB Server để kiểm tra %CPU ta có thể sử dụng query sau:

```sql
SELECT [cpu_idle] = record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int'),
       [cpu_sql]  = record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int'),
       [%_cpu]= 100 * record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') /
                (record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') +
                 record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]',
                              'int'))
FROM (
         SELECT TOP 1 CONVERT(XML, record) AS record
         FROM sys.dm_os_ring_buffers
         WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
           AND record LIKE '% %'
         ORDER BY TIMESTAMP DESC
     ) as cpu_usage
```

![image](/assets/images/sqlperf-3-maintain-cpu-4.png)

## 4. Tham khảo

[https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-requests-transact-sql?view=sql-server-2017](https://docs.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-requests-transact-sql?view=sql-server-2017)

[https://docs.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-who-transact-sql?view=sql-server-ver15](https://docs.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-who-transact-sql?view=sql-server-ver15)