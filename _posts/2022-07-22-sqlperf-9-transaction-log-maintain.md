---
layout: post
title:  "Quản lý Log File (ldf) và Shrink log"
description: "Cách SQLServer quản lý Transaction Log File và chiến thuật Shrink log hiệu quả"
tags: sql log
---

## 1. Transaction Log File

Là file LDF của một Database

Log File là thành phần quan trọng để đảm bảo tính ACID của DB

Dữ liệu log được ghi vào Transaction Log File (LDF) trước khi dữ liệu được ghi vào Data File (MDF). Quá trình này gọi là Write-ahead logging, đảm bảo dữ liệu ghi vào Data file được thực hiện tuần tự, toàn vẹn và có thể rollback

* Thể hiện tính nhất quán - Consistency (C) trong ACID

Ngoài ra, transaction log còn được sử dụng để phục hồi DB về một thời điểm cụ thể, trong trường hợp có sự cố

* Thể hiện tính bền vững – Durability (D) trong ACID

Một DB có thể có nhiều log file, và phải có ít nhất 1 log file

## 2. Virtual log file (VLF)

SQLServer chia một Transaction Log File (Physical file) thành các Virtual Log File (VLF)

Số lượng VLF và dung lượng của mỗi VLF là không cố định, các giá trị này phụ thuộc vào cấu hình của DB và lượng dữ liệu ghi vào DB. Tuy nhiên, 2 giá trị này ảnh hưởng trực tiếp đến hiệu năng của DB và quá trình backup/restore của DB

Log file growth chính là cấu hình ảnh hưởng đến 2 giá trị trên.

![image](/assets/images/sqlperf-9-1.png)

* Size cuả 1 VLF chính là giá trị Autogrowth trong cấu hình trên
* Số lượng VLF = Maxsize / Autogrowth
* Số lượng VLF tăng trưởng mỗi lần bên trong Log File được tính như sau:

| Size của transaction log chuẩn bị ghi vào               | Số VLF tạo ra (Tăng trưởng) |
|---------------------------------------------------------|:---------------------------:|
| < 1/8 physical log size hiện tại                        |              1              |
| > 1/8 physical log size hiện tại Và < 64MB              |              4              |
| > 1/8 physical log size hiện tại Và size In [64MB, 1GB] |              8              |
| > 1/8 physical log size hiện tại Và size > 1GB          |             16              |

### 2.1. Query kiểm tra VLF của tất cả DB trong Server

```sql
SELECT s.[name]                                                  AS 'Database Name',
       f.name                                                    AS 'Logical Name',
       COUNT(li.database_id)                                     AS 'VLF Count',
       SUM(li.vlf_size_mb)                                       AS 'VLF Size (MB)',
       SUM(CAST(li.vlf_active AS INT))                           AS 'Active VLF',
       SUM(li.vlf_active * li.vlf_size_mb)                       AS 'Active VLF Size (MB)',
       COUNT(li.database_id) - SUM(CAST(li.vlf_active AS INT))   AS 'Inactive VLF',
       SUM(li.vlf_size_mb) - SUM(li.vlf_active * li.vlf_size_mb) AS 'Inactive VLF Size (MB)'
FROM sys.databases s
         LEFT JOIN sys.master_files f on s.database_id = f.database_id AND f.type = 1
         CROSS APPLY sys.dm_db_log_info(s.database_id) li
GROUP BY s.[name], f.name
ORDER BY COUNT(li.database_id) DESC;
```

![image](/assets/images/sqlperf-9-2.png)

* ``Logical Name``: tên của Transaction Log File trong DB, khác với file name trên ổ đĩa
* ``VLF Count``: số lượng VLF trong 1 Transaction log file của DB
* ``VLF Size (MB)``: tổng size của VLF, chính là size của cả Transaction log file
* ``Active VLF``: các VLF đang được SQL Server sử dụng
* ``Inactive VLF``: các VLF không còn cần thiết cho SQL Server backup, commit,…

### 2.2. Query kiểm tra VLF của từng DB

```sql
SELECT * FROM sys.dm_db_log_info(DB_ID('EB88'))
```

![image](/assets/images/sqlperf-9-3.png)

* ``file_id``: là id của Transaction log file
* ``vlf_sequence_number``: thứ tự của VLF trong log file
* ``vlf_size_mb``: dung lượng của mỗi VLF (theo MB), đây chính là cấu hình Autogrowth của Log file

## Cách SQL Server quản lý VLF

Các VLF được sắp xếp theo thứ tự nhất quán, theo sequence number;

Dữ liệu được ghi vào VLF theo đúng thứ tự của sequence number, từ đầu đến cuối;

Quá trình truncate log chính là giải phóng các VLF không còn sử dụng, đó là các log từ đầu cho đến MinLSN. MinLSN – minimum log sequence number – là thứ tự của log file bé nhất mà SQL đang cần sử dụng.

![image](/assets/images/sqlperf-9-4.png)

Như ở ví dụ trên:
* VLF-3 chính là MinLSN
* VLF-1, VLF-2 có thể truncate, để SQLServer đánh dấu là không sử dụng. Các dữ liệu log mới sẽ ghi quay vòng được từ VLF-5 -> VLF-1 -> VLF-2
* Quá trình shrink log sẽ loại bỏ các VLF không sử dụng (Unused), và giảm kích thước của file log vật lý.

1 VLF được đánh dấu là inactive hoặc unused chỉ khi SQL Server không còn cần thiết đến VLF đó để recovery, tức là khi:
* Dữ liệu được commited hoàn toàn vào file mdf;
* SQLServer thực hiện backup log.

Vậy số lượng VLF chỉ tăng lên – tức là Transaction log file tăng trưởng kích thước – chỉ khi quá trình truncation đang không đủ so với dữ liệu log thêm mới vào. Ngược lại, các VLF sẽ được ghi quay vòng bên trong transaction log file.

## Shrink log (truncate VLF)

Dựa vào cách quản lý VLFs, ta có thể kiểm soát được sự tăng trưởng của dữ liệu ghi vào DB, thì có thể kiểm soát được sự tăng trưởng size của log file

Để đảm bảo quá trình truncate được thường xuyên và hiệu quả, cần có số lượng lớn nhất VLF inactive/unused, bằng cách:

* Dữ liệu được commited hoàn toàn vào file mdf: Thực hiện CHECKPOINT thường xuyên Đây là cách để commit các dữ liệu đã thay đổi ở Memory nhưng chưa thay đổi ở DISK (mdf file)
* Thực hiện backup log thường xuyên: Thông qua việc chạy Job Backup Transaction log

Trong trường hợp sự tăng trưởng size của Log vượt quá khả năng cung cấp tài nguyên DISK của máy chủ, cần shrink log để giảm size.

Cách Shrink log:

### 4.1. Bước 1: Checkpoint

```sql
USE EasyTVAN_Client

GO 

CHECKPOINT
```

### 4.2. Bước 2: Backup log

```sql
--backup log
BACKUP LOG EasyTVAN_Client TO  DISK = N'E:\BACKUP\EasyTVAN_Client.trn' WITH NOFORMAT, INIT, NOSKIP, REWIND, NOUNLOAD, COMPRESSION,  STATS = 5
```

* Cần thực hiện query backup log trên 1 vài lần để đảm bảo backup được tối đa (tối đa số VLF có thể truncate)
* Lưu ý, để có thể thực hiện được Backup log, đòi hỏi phải có 1 bản Backup Full data trước đó.
* Do đó việc tạo Job Backup data hàng tuần là rất cần thiết.
* Trong trường hợp không có bản Backup data, thực hiện:

```sql
--need backup full before backup log
BACKUP DATABASE EasyTVAN_Client TO  DISK = N'E:\BACKUP\\EasyTVAN_Client.bak' WITH  COPY_ONLY, FORMAT, INIT, SKIP, REWIND, NOUNLOAD, COMPRESSION,  STATS = 5
```

* Lưu ý: Cần đảm bảo đủ disk để backup data (rất quan trọng)

### 4.3. Bước 3: Shrink log file

```sql
--shrink log file to 256MB
DBCC SHRINKFILE ('EasyTVAN_Client_log', 256)
```

* ``EasyTVAN_Client_log``: Lấy theo Logical Name trong query kiểm tra ở phần 2.1
* Cần thực hiện query trên 1 vài lần để đảm bảo quá trình thực hiện thành công
* Kiểm tra lại kết quả bằng cách chạy lại query ở phần 2.1.

## Tham khảo

[https://docs.microsoft.com/](https://docs.microsoft.com/en-us/sql/relational-databases/sql-server-transaction-log-architecture-and-management-guide?view=sql-server-ver16)

[https://www.sqlshack.com/](https://www.sqlshack.com/sql-server-transaction-log-architecture/)
