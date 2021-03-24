---
layout: post
title:  "Các công việc maintain Database thường xuyên - Phần 1"
description: "Phần 1: Tìm query gây cao tải CPU"
tags: sql maintain cpu dba

---

## Liệt kê các query/session đang tốn CPU

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

* Status chỉ cần là 1 trong 3 trạng thái ```Suspended``` ```Running``` ```Runnable```. Đặc biệt ta không quan tâm đến trạng thái ```Background```, đây là trạng thái dành cho các Background Task của SQLServer.
* Wait_time: là thời gian query/transaction phải đợi để có thể lấy resource đang request.
* Cpu_time: là thời gian xử lý của CPU (theo millisecond) cho query/transaction.

Ở đây ta quan tâm chủ yếu đến ```cpu_time``` và ```wait_time```. 2 yếu tố này thể hiện thời gian CPU phải xử lý request, và các số này cao và đang tăng giữa các lần exec query trên thể hiện session/query/transaction tương ứng đang gây cao tải ở CPU.
