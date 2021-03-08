---
layout: post
title:  "Các cấu hình cần thiết cho SQLServer để tăng hiệu năng (P2)"
description: "Phần 1: Cấu hình về DataBase files, TempDB files, Parallelism"
tags: sql configuration dba
---

## 1. Phân chia ổ đĩa

Theo mặc định, SQL Server ghi tất cả dữ liệu Data/Log/TempDB vào cùng một thư mục.

Điều này gây ra stress Read/Write lên phân vùng, thư mục đó. Vì vậy để tối ưu chúng ta tách riêng thành các ổ đĩa như sau:
* Một ổ đĩa dành cho TempDB.
* Một ổ đĩa dành cho DataFile.
* Một ổ đĩa dành cho LogFile.
* Một ổ đĩa dành cho BackupFile.

## 2. Chia lại phân vùng cho Data và Log

Check thư mục hiện tại đang sử dụng:

```sql
SELECT name,physical_name
FROM [DB_name].sys.database_files;
```

![image](/assets/images/sqlperf-1-config-5.png)

Chuyển thư mục:

```sql
ALTER DATABASE EASYBOOKS
MODIFY FILE (NAME = EASYBOOKS, FILENAME = 'D:\Data\EASYBOOKS_2020.mdf');
ALTER DATABASE EASYBOOKS
MODIFY FILE (NAME = EASYBOOKS_Log, FILENAME = 'L:\Log\EASYBOOKS_2020_Log.ldf');
```

* Restart lại DB sau khi chuyển.

## 3. Cấu hình FileGrowth cho Data và Log

Tức là cho phép khả năng tăng trưởng mỗi lần của file Data và Log. Khuyến nghị ở đây là:
* 256MB dành cho Data
* 128MB dành cho Log

```sql
USE master

ALTER DATABASE EASYBOOKS MODIFY FILE ( NAME = N'EASYBOOKS', FILEGROWTH = 256MB )

ALTER DATABASE EASYBOOKS MODIFY FILE (NAME = N'EASYBOOKS_log', FILEGROWTH = 128MB )
```

## 4. Cấu hình cho TempDB

### 4.1. Chuyển thư mục khác cho TempDB

Mặc định TempDB ở cùng thư mục cài đặt với Data/Log/Binary file của SQLServer. Để tối ưu ta chuyển TempDB sang thư mục khác:

```sql
use master;
GO
alter database tempdb modify file (name='tempdev', filename='T:\MSSQL\DATA\tempDB.mdf', size = 1MB);
GO
alter database tempdb modify file (name='templog', filename='L:\MSSQL\LOGS\templog.ldf', size = 1MB);
GO
```

Có một chút trick ở đây đó là ta sét fileSize là 1MB bởi vì, trong câu sql chỉ ra ta dùng thư mục khác để lưu file, nhưng SQLServer vẫn lấy space ở thư mục hiện tại. Do đó ta set trước 1MB và điều chỉnh sau.

* Restart SQLServer.

### 4.2. Cấu hình TempDB

Tư tưởng là như sau: Với dung lượng đã cấp cho thư mục chứa file Temp, ta sẽ cấp phát sẵn **90%** dung lượng thư mục này cho tempDB và không cho phép tự động tăng trưởng.

Đồng thời **tạo sẵn** số lượng tempDB bằng với số lượng logicalProcessor của máy chủ, **nhưng tối đa là 8**. Bởi vì SQLServer tự động tạo thêm tempDB nếu đạt đến giới hạn dung lượng tối đa của tempDB hiện tại, và quá trình tự động này sẽ gây ra **phân mảnh dữ liệu** nếu ta cấp phát cho mỗi tempDB dung lượng quá nhỏ.

Kiểm tra bằng query:

```sql
SELECT (cpu_count / hyperthread_ratio) AS PhysicalCPUs,
cpu_count AS logicalCPUs
FROM sys.dm_os_sys_info
```

Ví dụ ta có 50GB dành cho tempDB, máy chủ có 8 processor; tạo 8 tempDb và cấp cho mỗi DB 5GB và khóa autoGrowth.

Chỉnh sửa tempDB hiện tại, cấp phát thêm dung lượng:

```sql
USE [master];
GO
alter database tempdb modify file (name='tempdev', size = 5GB);
GO 
```

Tạo sẵn temdb2:

```sql
USE [master];
GO
ALTER DATABASE [tempdb] ADD FILE (NAME = N'tempdev2', FILENAME =
N'T:\MSSQL\DATA\tempdev2.ndf' , SIZE = 5GB , FILEGROWTH = 0)
GO 
```

Cứ như vậy tạo đủ 8 tempDB.

Sau đó trong quá trình sử dụng, quan sát các tempDb, ta có thể cấp thêm dung lượng cho file tăng trưởng nhanh nhất trong 8 file đó.

> Tốt nhất là khi cài, SQL Server sẽ tự nhận biết số lượng tempDB cần thiết; ta có thể cấu hình initSize hay autoGrowth và location ở đây (hình dưới)

![image](/assets/images/sqlperf-1-config-6.png)

## 5. Cấu hình tính toán song song (Parallelism)

### 5.1. MAXDOP (Max Degree of Parallelism)

MAXDOP là cấu hình cho phép SQLServer sử dụng bao nhiêu Processor của CPU để thực hiện các query (plan execution)

Mặc định SQLServer để MAXDOP = 0 là cho phép dùng tất cả các processor có thể của máy chủ và max = 64.

Tuy nhiên Microsoft cũng recommend là không nên để 0, thay vào đó là set [như ở đây](https://docs.microsoft.com/en-us/sql/database-engine/configure-windows/configure-the-max-degree-of-parallelism-server-configuration-option?view=sql-server-2017#Recommendations)

Đơn giản hơn ta có thể set theo kết quả của query dưới đây:

```sql
USE master
GO
SELECT COUNT(*)
FROM sys.dm_os_schedulers
WHERE scheduler_id <= 1048575
  AND is_online = 1;
```

Sau đó thực hiện thay đổi cấu hình, ở đây kết quả query trên là **16**:

```sql
USE EASYBOOKS;  
GO   
EXEC sp_configure 'show advanced options', 1;  
GO  
RECONFIGURE WITH OVERRIDE;  
GO  
EXEC sp_configure 'max degree of parallelism', 16;  
GO  
RECONFIGURE WITH OVERRIDE;  
GO 
```

### 5.2. Cấu hình SQL Server Cost Threshold for Parallelism

Đây là giá trị cấu hình ngưỡng chi phí của 1 query mà ở đó SQLServer bắt đầu xem xét thực thi query đó bằng multiple thread.

Thông thường các query đơn giản có cost **< 50**

Trong khi đó default của SQLServer là **5**, quá bé, ta set ngưỡng này là **50** (tức là dưới 50 thì không cần chạy song song nhiều thread)

```sql
USE EASYBOOKS ;  
GO  
EXEC sp_configure 'show advanced options', 1 ;  
GO  
RECONFIGURE  
GO  
EXEC sp_configure 'cost threshold for parallelism', 50 ;  
GO  
RECONFIGURE  
GO 
```

## Hết phần 2...
