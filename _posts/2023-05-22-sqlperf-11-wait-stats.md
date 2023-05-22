---
layout: post
title:  "Wait statistics"
description: "Một trong các kỹ thuật phổ biến để tìm điểm nghẽn (bottlenecks) của SQL Server (bài viết dài)"
tags: sql wait dba
---

> Đa phần sử dụng kỹ thuật này để dò tìm các truy vấn đang hold lock trong hệ thống. 
> Ngoài ra kỹ thuật này được dùng thường xuyên để đánh giá hiệu năng chung cho: CPU, I/O, Network,...

## Bài toán thực tế

Trong hệ thống OLTP database của SDS thường gặp các phản hồi bất thường (tức là chưa có cảnh báo từ trước), thì để dò xét nguyên nhân, một trong các cách có thể dùng là dựa vào built-in DMV wait.

Các nguyên nhân thường gặp:

* Các query đang bị block (do một tiến trình/query khác đang lock tài nguyên);
* Tiến trình đồng bộ transaction log (giữa các node của AAG) đang thực hiện;
* Các ứng dụng xử lý dữ liệu trả về quá chậm, dẫn đến thời gian hold lock quá lâu...

Các built-in DMV này cung cấp các thông tin chủ yếu liên quan đến các Wait Type (có thể hiểu nôm na là các trường hợp mà 1 tiến trình phải chờ, vd: chờ lấy lock), mà dựa vào các thông tin này chúng ta có thể biết được query, tiến trình nào đang gây lock hay các vấn đề liên quan đến network, disk I/O, memory, CPU, AAG...

2 DMV sử dụng ở đây: **``sys.dm_os_waiting_tasks``**, **``sys.dm_os_waiting_stats``**

## Một chút lý thuyết cơ bản liên quan

_Nói về lý thuyết một chút trước khi giới thiệu về 2 DMV trên, để hiểu rõ hơn nguồn gốc của các sự kiên wait trong SQL Server, cũng như tại sao chúng ta lại cần 2 DMV trên._

Khi có 1 request tạo connection từ client, SQLServer auth client, tạo connection và trả về ``session_id`` cho client. Kể từ đó client có thể bắt đầu tạo request, ví dụ như truy vấn dữ liệu. Ngay khi nhận request, SQLServer tạo task để bắt đầu xử lý.

Hình dưới đây mô tả ở mức thấp quá trình SQL Server xử lý cho 1 request:

![image](/assets/images/sqlperf-11-1.png)

* Các task sẽ được thực thi trên ``worker_thread`` mà hệ điều hành cấp cho SQLServer. SQLServer quản lý các ``worker_thread`` này thông qua thread pool.
* Việc quyết định một task sẽ dùng (một-hay nhiều) ``worker_thread`` nào được điều khiển bằng ``SQLOS Scheduler`` (engine của SQLServer).
* Tùy vào độ phức tạp, Task cần thực hiện có thể được chia nhỏ thành nhiều sub-task và được thực thi trên nhiều ``worker_thread`` (đây chính là khả năng tính toán song song của SQLServer).
* Thông thường, số lượng ``Scheduler`` sẽ tương ứng với số CPU core của OS (8-core CPU -> 8 SQLOS scheduler). Chúng ta có thể cấu hình, customize như ở đây...). Tại 1 thời điểm, chỉ có 1 ``worker_thread`` được phép chạy trên 1 CPU.

### Một thread chỉ có thể tồn tại ở 1 trong 3 trạng thái sau:

* ``RUNNING``: đang chạy trên CPU
* ``SUSPENDED``: khi thread cần tài nguyên (resource), ví dụ dữ liệu trên memory; thread sẽ được đẩy vào ``waiter_list``, và trạng thái chuyển thành ``SUSPENDED``, cho đến khi resource đó sẵn sàng (ví dụ như lock trên data được release)
* ``RUNNABLE``: nếu thread không cần tài nguyên, nhưng trong thời điểm đó ``scheduler`` đang xử lý một thread khác. Khi đó thread ban đầu sẽ được đưa vào ``runnable_queue`` và có trạng thái là ``RUNNABLE``.

Hình dưới đây mô tả vòng đời trạng thái của thread:

![image](/assets/images/sqlperf-11-2.png)

Như ở ví dụ trên:

* ``Session 55`` có trạng thái là ``RUNNING`` vì đang được chạy trên CPU;
* ``Session 52`` không cần tài nguyên, nhưng do ``Session 55`` đang chạy nên phải chờ ở ``runnable_queue``, và có trạng thái là ``RUNNABLE``;
* ``Session 53`` đang chờ lấy lock ``LCK_M_S`` nên nó có trạng thái ``SUSPENDED``, và được xếp ở ``waiter_list`` (Lock ``LCK_M_S`` là lock để read resource).

### Chúng ta quan tâm đến 2 giá trị thời gian:

* SQLOS theo dõi thời gian 1 thread tồn tại ở trạng thái ``SUSPENDED`` (trong ``waiter_list`` cho đến khi được chuyển sang ``runnable_queue``), gọi là **``resource_time``**.
* Tương tự, thời gian 1 thread tồn tại ở trạng thái ``RUNNABLE`` cho đến khi CPU thông báo (signal) và cho chạy, gọi là **``signal_wait``**. Có thể hiểu nôm na đây chính là thời gian chờ CPU.

Và như thế, thời gian để 1 thread bắt đầu được xử lý đến khi thực hiện ở CPU chính là **``total_wait_time`` = ``resource_wait`` + ``signal_wait``**.

3 chỉ số trên là 1 trong những yếu tố chính từ kết quả trả về từ 2 built-in DMV mà chúng ta sẽ sử dụng sau đây: ``sys.dm_os_waiting_tasks``, ``sys.dm_os_waiting_stats``.

## Kiểm tra các sự kiện đang wait ở thời điểm hiện tại (real time)

> sys.dm_os_waiting_tasks

Sử dụng query sau, để có thể lấy ra được cả nội dung các truy vấn:

```sql
SELECT blocking.session_id AS blocking_session_id,
       blocked.session_id  AS blocked_session_id,
       waitstats.wait_type AS blocking_resource,
       waitstats.wait_duration_ms,
       waitstats.resource_description,
       blocked_cache.text  AS blocked_text,
       blocking_cache.text AS blocking_text
FROM sys.dm_exec_connections AS blocking
         INNER JOIN sys.dm_exec_requests blocked ON blocking.session_id = blocked.blocking_session_id
         CROSS APPLY sys.dm_exec_sql_text(blocked.sql_handle) blocked_cache
         CROSS APPLY sys.dm_exec_sql_text(blocking.most_recent_sql_handle) blocking_cache
         INNER JOIN sys.dm_os_waiting_tasks waitstats ON waitstats.session_id = blocked.session_id;
```

Lưu ý kết quả trả về sẽ là các transaction **đang block** các transaction khác ở thời điểm hiện tại (real-time).

Kết quả này cũng tương tự như khi chúng ta sử dụng query ở [bài viết này]({% post_url 2021-03-05-sqlperf-maintain-cpu %})

![image](/assets/images/sqlperf-11-3.png)

Trong ví dụ trên, ``session 51`` đang nắm khóa (wait_type) ``LCK_M_S``, và ``session 56`` đã bị block.

Từ đây ta có thể tìm cách tuning để ``session 51`` thực hiện nhanh hơn,...

## Kiểm tra lịch sử, toàn bộ wait để dò tìm bottlenecks

> sys.dm_os_waiting_stats

Dynamic View này trả về giá trị tích lũy của tất cả ``wait_type`` _**kể từ lần gần nhất SQLServer restart**_.

Ta xem xét kết quả trả về từ _**query sau**_ (đã loại bỏ các ``wait_type`` thường không phải là vấn đề hiệu năng):

```sql
-- Last updated October 1, 2021
WITH [Waits] AS
    (SELECT
        [wait_type],
        [wait_time_ms] / 1000.0 AS [WaitS],
        ([wait_time_ms] - [signal_wait_time_ms]) / 1000.0 AS [ResourceS],
        [signal_wait_time_ms] / 1000.0 AS [SignalS],
        [waiting_tasks_count] AS [WaitCount],
        100.0 * [wait_time_ms] / SUM ([wait_time_ms]) OVER() AS [Percentage],
        ROW_NUMBER() OVER(ORDER BY [wait_time_ms] DESC) AS [RowNum]
    FROM sys.dm_os_wait_stats
    WHERE [wait_type] NOT IN (
        -- These wait types are almost 100% never a problem and so they are
        -- filtered out to avoid them skewing the results. Click on the URL
        -- for more information.
        N'BROKER_EVENTHANDLER', -- https://www.sqlskills.com/help/waits/BROKER_EVENTHANDLER
        N'BROKER_RECEIVE_WAITFOR', -- https://www.sqlskills.com/help/waits/BROKER_RECEIVE_WAITFOR
        N'BROKER_TASK_STOP', -- https://www.sqlskills.com/help/waits/BROKER_TASK_STOP
        N'BROKER_TO_FLUSH', -- https://www.sqlskills.com/help/waits/BROKER_TO_FLUSH
        N'BROKER_TRANSMITTER', -- https://www.sqlskills.com/help/waits/BROKER_TRANSMITTER
        N'CHECKPOINT_QUEUE', -- https://www.sqlskills.com/help/waits/CHECKPOINT_QUEUE
        N'CHKPT', -- https://www.sqlskills.com/help/waits/CHKPT
        N'CLR_AUTO_EVENT', -- https://www.sqlskills.com/help/waits/CLR_AUTO_EVENT
        N'CLR_MANUAL_EVENT', -- https://www.sqlskills.com/help/waits/CLR_MANUAL_EVENT
        N'CLR_SEMAPHORE', -- https://www.sqlskills.com/help/waits/CLR_SEMAPHORE
 
        -- Maybe comment this out if you have parallelism issues
        N'CXCONSUMER', -- https://www.sqlskills.com/help/waits/CXCONSUMER
 
        -- Maybe comment these four out if you have mirroring issues
        N'DBMIRROR_DBM_EVENT', -- https://www.sqlskills.com/help/waits/DBMIRROR_DBM_EVENT
        N'DBMIRROR_EVENTS_QUEUE', -- https://www.sqlskills.com/help/waits/DBMIRROR_EVENTS_QUEUE
        N'DBMIRROR_WORKER_QUEUE', -- https://www.sqlskills.com/help/waits/DBMIRROR_WORKER_QUEUE
        N'DBMIRRORING_CMD', -- https://www.sqlskills.com/help/waits/DBMIRRORING_CMD
        N'DIRTY_PAGE_POLL', -- https://www.sqlskills.com/help/waits/DIRTY_PAGE_POLL
        N'DISPATCHER_QUEUE_SEMAPHORE', -- https://www.sqlskills.com/help/waits/DISPATCHER_QUEUE_SEMAPHORE
        N'EXECSYNC', -- https://www.sqlskills.com/help/waits/EXECSYNC
        N'FSAGENT', -- https://www.sqlskills.com/help/waits/FSAGENT
        N'FT_IFTS_SCHEDULER_IDLE_WAIT', -- https://www.sqlskills.com/help/waits/FT_IFTS_SCHEDULER_IDLE_WAIT
        N'FT_IFTSHC_MUTEX', -- https://www.sqlskills.com/help/waits/FT_IFTSHC_MUTEX
  
       -- Maybe comment these six out if you have AG issues
        N'HADR_CLUSAPI_CALL', -- https://www.sqlskills.com/help/waits/HADR_CLUSAPI_CALL
        N'HADR_FILESTREAM_IOMGR_IOCOMPLETION', -- https://www.sqlskills.com/help/waits/HADR_FILESTREAM_IOMGR_IOCOMPLETION
        N'HADR_LOGCAPTURE_WAIT', -- https://www.sqlskills.com/help/waits/HADR_LOGCAPTURE_WAIT
        N'HADR_NOTIFICATION_DEQUEUE', -- https://www.sqlskills.com/help/waits/HADR_NOTIFICATION_DEQUEUE
        N'HADR_TIMER_TASK', -- https://www.sqlskills.com/help/waits/HADR_TIMER_TASK
        N'HADR_WORK_QUEUE', -- https://www.sqlskills.com/help/waits/HADR_WORK_QUEUE
 
        N'KSOURCE_WAKEUP', -- https://www.sqlskills.com/help/waits/KSOURCE_WAKEUP
        N'LAZYWRITER_SLEEP', -- https://www.sqlskills.com/help/waits/LAZYWRITER_SLEEP
        N'LOGMGR_QUEUE', -- https://www.sqlskills.com/help/waits/LOGMGR_QUEUE
        N'MEMORY_ALLOCATION_EXT', -- https://www.sqlskills.com/help/waits/MEMORY_ALLOCATION_EXT
        N'ONDEMAND_TASK_QUEUE', -- https://www.sqlskills.com/help/waits/ONDEMAND_TASK_QUEUE
        N'PARALLEL_REDO_DRAIN_WORKER', -- https://www.sqlskills.com/help/waits/PARALLEL_REDO_DRAIN_WORKER
        N'PARALLEL_REDO_LOG_CACHE', -- https://www.sqlskills.com/help/waits/PARALLEL_REDO_LOG_CACHE
        N'PARALLEL_REDO_TRAN_LIST', -- https://www.sqlskills.com/help/waits/PARALLEL_REDO_TRAN_LIST
        N'PARALLEL_REDO_WORKER_SYNC', -- https://www.sqlskills.com/help/waits/PARALLEL_REDO_WORKER_SYNC
        N'PARALLEL_REDO_WORKER_WAIT_WORK', -- https://www.sqlskills.com/help/waits/PARALLEL_REDO_WORKER_WAIT_WORK
        N'PREEMPTIVE_OS_FLUSHFILEBUFFERS', -- https://www.sqlskills.com/help/waits/PREEMPTIVE_OS_FLUSHFILEBUFFERS
        N'PREEMPTIVE_XE_GETTARGETSTATE', -- https://www.sqlskills.com/help/waits/PREEMPTIVE_XE_GETTARGETSTATE
        N'PVS_PREALLOCATE', -- https://www.sqlskills.com/help/waits/PVS_PREALLOCATE
        N'PWAIT_ALL_COMPONENTS_INITIALIZED', -- https://www.sqlskills.com/help/waits/PWAIT_ALL_COMPONENTS_INITIALIZED
        N'PWAIT_DIRECTLOGCONSUMER_GETNEXT', -- https://www.sqlskills.com/help/waits/PWAIT_DIRECTLOGCONSUMER_GETNEXT
        N'PWAIT_EXTENSIBILITY_CLEANUP_TASK', -- https://www.sqlskills.com/help/waits/PWAIT_EXTENSIBILITY_CLEANUP_TASK
        N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', -- https://www.sqlskills.com/help/waits/QDS_PERSIST_TASK_MAIN_LOOP_SLEEP
        N'QDS_ASYNC_QUEUE', -- https://www.sqlskills.com/help/waits/QDS_ASYNC_QUEUE
        N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
            -- https://www.sqlskills.com/help/waits/QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP
        N'QDS_SHUTDOWN_QUEUE', -- https://www.sqlskills.com/help/waits/QDS_SHUTDOWN_QUEUE
        N'REDO_THREAD_PENDING_WORK', -- https://www.sqlskills.com/help/waits/REDO_THREAD_PENDING_WORK
        N'REQUEST_FOR_DEADLOCK_SEARCH', -- https://www.sqlskills.com/help/waits/REQUEST_FOR_DEADLOCK_SEARCH
        N'RESOURCE_QUEUE', -- https://www.sqlskills.com/help/waits/RESOURCE_QUEUE
        N'SERVER_IDLE_CHECK', -- https://www.sqlskills.com/help/waits/SERVER_IDLE_CHECK
        N'SLEEP_BPOOL_FLUSH', -- https://www.sqlskills.com/help/waits/SLEEP_BPOOL_FLUSH
        N'SLEEP_DBSTARTUP', -- https://www.sqlskills.com/help/waits/SLEEP_DBSTARTUP
        N'SLEEP_DCOMSTARTUP', -- https://www.sqlskills.com/help/waits/SLEEP_DCOMSTARTUP
        N'SLEEP_MASTERDBREADY', -- https://www.sqlskills.com/help/waits/SLEEP_MASTERDBREADY
        N'SLEEP_MASTERMDREADY', -- https://www.sqlskills.com/help/waits/SLEEP_MASTERMDREADY
        N'SLEEP_MASTERUPGRADED', -- https://www.sqlskills.com/help/waits/SLEEP_MASTERUPGRADED
        N'SLEEP_MSDBSTARTUP', -- https://www.sqlskills.com/help/waits/SLEEP_MSDBSTARTUP
        N'SLEEP_SYSTEMTASK', -- https://www.sqlskills.com/help/waits/SLEEP_SYSTEMTASK
        N'SLEEP_TASK', -- https://www.sqlskills.com/help/waits/SLEEP_TASK
        N'SLEEP_TEMPDBSTARTUP', -- https://www.sqlskills.com/help/waits/SLEEP_TEMPDBSTARTUP
        N'SNI_HTTP_ACCEPT', -- https://www.sqlskills.com/help/waits/SNI_HTTP_ACCEPT
        N'SOS_WORK_DISPATCHER', -- https://www.sqlskills.com/help/waits/SOS_WORK_DISPATCHER
        N'SP_SERVER_DIAGNOSTICS_SLEEP', -- https://www.sqlskills.com/help/waits/SP_SERVER_DIAGNOSTICS_SLEEP
        N'SQLTRACE_BUFFER_FLUSH', -- https://www.sqlskills.com/help/waits/SQLTRACE_BUFFER_FLUSH
        N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', -- https://www.sqlskills.com/help/waits/SQLTRACE_INCREMENTAL_FLUSH_SLEEP
        N'SQLTRACE_WAIT_ENTRIES', -- https://www.sqlskills.com/help/waits/SQLTRACE_WAIT_ENTRIES
        N'VDI_CLIENT_OTHER', -- https://www.sqlskills.com/help/waits/VDI_CLIENT_OTHER
        N'WAIT_FOR_RESULTS', -- https://www.sqlskills.com/help/waits/WAIT_FOR_RESULTS
        N'WAITFOR', -- https://www.sqlskills.com/help/waits/WAITFOR
        N'WAITFOR_TASKSHUTDOWN', -- https://www.sqlskills.com/help/waits/WAITFOR_TASKSHUTDOWN
        N'WAIT_XTP_RECOVERY', -- https://www.sqlskills.com/help/waits/WAIT_XTP_RECOVERY
        N'WAIT_XTP_HOST_WAIT', -- https://www.sqlskills.com/help/waits/WAIT_XTP_HOST_WAIT
        N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', -- https://www.sqlskills.com/help/waits/WAIT_XTP_OFFLINE_CKPT_NEW_LOG
        N'WAIT_XTP_CKPT_CLOSE', -- https://www.sqlskills.com/help/waits/WAIT_XTP_CKPT_CLOSE
        N'XE_DISPATCHER_JOIN', -- https://www.sqlskills.com/help/waits/XE_DISPATCHER_JOIN
        N'XE_DISPATCHER_WAIT', -- https://www.sqlskills.com/help/waits/XE_DISPATCHER_WAIT
        N'XE_TIMER_EVENT' -- https://www.sqlskills.com/help/waits/XE_TIMER_EVENT
        )
    AND [waiting_tasks_count] > 0
    )
SELECT
    MAX ([W1].[wait_type]) AS [WaitType],
    CAST (MAX ([W1].[WaitS]) AS DECIMAL (16,2)) AS [Wait_S],
    CAST (MAX ([W1].[ResourceS]) AS DECIMAL (16,2)) AS [Resource_S],
    CAST (MAX ([W1].[SignalS]) AS DECIMAL (16,2)) AS [Signal_S],
    MAX ([W1].[WaitCount]) AS [WaitCount],
    CAST (MAX ([W1].[Percentage]) AS DECIMAL (5,2)) AS [Percentage],
    CAST ((MAX ([W1].[WaitS]) / MAX ([W1].[WaitCount])) AS DECIMAL (16,4)) AS [AvgWait_S],
    CAST ((MAX ([W1].[ResourceS]) / MAX ([W1].[WaitCount])) AS DECIMAL (16,4)) AS [AvgRes_S],
    CAST ((MAX ([W1].[SignalS]) / MAX ([W1].[WaitCount])) AS DECIMAL (16,4)) AS [AvgSig_S]
FROM [Waits] AS [W1]
INNER JOIN [Waits] AS [W2] ON [W2].[RowNum] <= [W1].[RowNum]
GROUP BY [W1].[RowNum]
HAVING SUM ([W2].[Percentage]) - MAX( [W1].[Percentage] ) < 95; -- percentage threshold
GO
```

![image](/assets/images/sqlperf-11-4.png)

Để đánh giá được vấn đề bottlenecks, hay để hiểu ý nghĩa của kết quả ở trên, chúng ta đầu tiên cần hiểu được ý nghĩa của một số ``wait_type`` phổ biến thường gặp ở hệ thống OLTP.

### Một số ``Wait_type`` thường gặp trong các hệ thống OLTP

#### LCK_*

Đây chính là lock trên tài nguyên, khi một session cần lấy 1 lock nhưng lock này lại đang được nắm giữ bởi một session khác.

* ``LCK_M_S``: lock để select tài nguyên;
* ``LCK_M_X``, ``LCK_M_IX``, ``LCK_M_U``: lock để update tài nguyên;
* ``LCK_M_SCH_S``: lock tài nguyên để thay đổi schema (ví dụ thường thấy là session đó đang rebuild index) 

Để giảm thiểu blocking trên những ``wait_type`` này, thông thường chúng ta thường review lại các query liên quan để giảm thiểu xung đột (xem xét index sử dụng trong các query,...)

Riêng với ``LCK_M_SCH_S`` ta có thể xem lại các task đang thực hiện rebuild, reorganize index trên db đã chạy vào các thời điểm hợp lý chưa. Vì nó là giá trị tích lũy qua các lần rebuild, nên chưa hẳn đã là vấn đề hiệu năng.

#### HADR_SYNC_COMMIT

Đây là ``wait_type`` khi hệ thống AAG đồng bộ transaction log từ node primary về node secondary (tức là node secondary chạy AAG với mode ``synchronous_commit``).

Wait type này chưa hẳn là một vấn đề hiệu năng. Nhưng nếu ``wait_time`` tích lũy quá cao, chúng ta cần xem xét đến các vấn đề như:

* Cấu hình trên các node AAG đang không tương đương nhau (secondary cấu hình CPU thấp hơn chẳng hạn);
* Network giữa các node có quá tải hay không;
* 1 node secondary có nhất thiết chạy với ``synchronous_commit`` không, có thể cấu hình ``asynchronous_commit`` nếu 2 node khác DC.

#### PAGEIOLATCH_*

Wait type này thể hiện việc đọc/ghi dữ liệu (I/O) từ ``mdf file`` và ``buffer cache`` (memory) của SQL Server.

Nếu ``wait_time`` lớn có thể xem xét các nguyên nhân sau:

* Ổ đĩa ``read/write`` chậm, có thể xem xét dựa vào query bên dưới;
* Quá tải ở ``tempdb``: Thêm/xóa 1 lượng lớn dữ liệu ở ``tempdb``;
* Thiếu memory dẫn đến việc thường xuyên phải lấy dữ liệu từ disk thay vì ở buffer_cache...

_Query kiểm tra tốc độ read/write của disk có đang trễ hay không:_

```sql
-- The Average Total Latency
-- Excellent <1 ms
--
-- Very good <5 ms
--
-- Good <5 – 10 ms
--
-- Poor < 10 – 20 ms
--
-- Bad < 20 – 100 ms
--
-- Very Bad <100 ms -500 ms
--
-- Awful > 500 ms
--
-- sample_ms - bigint- Number of milliseconds since the computer was started. This column can be used to compare different outputs from this function.
SELECT sample_ms,
       CAST(io_stall_read_ms / (1.0 + num_of_reads) AS NUMERIC(10, 1))   AS [Average Read latency ms],
       CAST(io_stall_write_ms / (1.0 + num_of_writes) AS NUMERIC(10, 1)) AS [Average Write latency ms],
       CAST((io_stall_read_ms + io_stall_write_ms)
           / (1.0 + num_of_reads + num_of_writes)
           AS NUMERIC(10, 1))                                            AS [Average Total Latency ms]
FROM sys.dm_io_virtual_file_stats(DB_ID(), NULL)
WHERE FILE_ID <> 2;
```

#### WRITELOG

Đây cũng là 1 ``wait_type`` liên quan đến Disk I/O.

Ghi nhận thời gian chờ khi SQL Server thực hiện ghi dữ liệu từ ``buffer_cache`` xuống ``transaction_log_file`` (ldf).

Có thể xem xét phân bổ lại phân vùng của các file mdf, ldf, tempdb để tránh cao tải trên 1 phân vùng ổ đĩa ([xem bài viết]({% post_url 2021-03-08-sqlperf-1-config-checklist-2 %}))

#### ASYNC_NETWORK_IO

Tuy có chữ _network_ trong tên nhưng wait này không liên quan gì đến vấn đề network cả.

Thực tế vấn đề nằm ở **_Client đang xử lý dữ liệu trả về từ truy vấn quá lâu_** (chưa thể end transaction). Ví dụ, query trả về result_set 10.000 row, Java Spring app xử lý row-by-row để mapping đối tượng (Hibernate chẳng hạn), và chưa thể kết thúc transaction.

Cách xử lý là xem xét lại source code từ client đang thực hiện xử lý result_set trả về từ truy vấn. Ví dụ nhận result_set, thực hiện end transaction trước khi xử lý result_set.

#### CXPACKET

_Bản thân wait này, kể cả wait_time cao hay thấp, không phải là vấn đề hiệu năng._

Nó ghi nhận thời gian khi một worker_thread kết thúc sub_task (trong một quá trình tính toán song song), nhanh hơn các worker_thread khác đang cùng thực hiện sub_task từ task tương ứng.

Giống như 1 nhân viên A giỏi và xử lý vấn đề nhanh hơn các nhân viên khác. 
A kết thúc công việc trước, và kêu lên với sếp "Mấy thằng kia chậm quá, cho tao task mới đi"; 
khi đó SQL Server ghi nhận wait_time là thời gian lúc A kêu đến khi có task mới.

_Tuy nhiên nếu không có ``CXPACKET`` từ lịch sử, lại là vấn đề,_ khi đó ta cần xem xét các cấu hình liên quan đến tính toán song song ([xem bài viết]({% post_url 2021-03-08-sqlperf-1-config-checklist-2 %}))

#### SOS_SCHEDULER_YIELD

Có một trường hợp khi 1 thread đang chạy ở CPU (``RUNNING``) tuy nhiên quá 4ms vẫn chưa thể thực hiện, thread này bị đưa quay về trạng thái ``RUNNABLE`` và back về ``running_queue``.
Và loại wait này ghi nhận thời gian để thread đó có thể rời queue và quay lại trạng thái chạy ở CPU.

Loại wait này cũng thể hiện rằng có thể CPU đang thiếu.

## Kết luận

Dựa vào 2 DMV trên, chúng ta có thể có thêm công cụ, kỹ thuật để có thể phát hiện các vấn đề hiệu năng với SQL Server;
cũng như phát hiện một số logic ở ứng dụng chưa chính xác.

Từ đó có thể sử dụng thêm các công cụ, query khác để có thêm thông tin về các điểm nghẽn hiệu năng ở Disk I/O, CPU, Network, Memory,...

Việc đo lường thường xuyên (maintain) dựa trên DMV ``sys.dm_os_waiting_stats`` là cần thiết, và dựa trên ``baseline`` của mỗi hệ thống ứng dụng,
để có thể xác định được liệu có các chỉ số nào đang vượt ngưỡng hay không. Chúng ta sẽ đi sâu vào vấn đề này ở các bài viết sau.

## Tham khảo

[https://www.red-gate.com/products/dba/sql-monitor/resources/articles/monitor-sql-server-io](https://www.red-gate.com/products/dba/sql-monitor/resources/articles/monitor-sql-server-io)

[https://www.sqlskills.com/blogs/paul/wait-statistics-or-please-tell-me-where-it-hurts/](https://www.sqlskills.com/blogs/paul/wait-statistics-or-please-tell-me-where-it-hurts/)

[https://www.brentozar.com/archive/2013/08/what-is-the-cxpacket-wait-type-and-how-do-you-reduce-it/](https://www.brentozar.com/archive/2013/08/what-is-the-cxpacket-wait-type-and-how-do-you-reduce-it/)

[White Paper by Jonathan Kehayias and Erin Stellato: SQL Server Performance Tuning Using Wait Statistics: A Beginner’s Guide](https://www.sqlskills.com/wp-content/uploads/2014/04/sql-server-performance-tuning-using-wait-statistics-whitepaper.pdf)
