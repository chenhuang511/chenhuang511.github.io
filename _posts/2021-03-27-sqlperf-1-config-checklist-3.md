---
layout: post
title:  "Các cấu hình cần thiết cho SQLServer để tăng hiệu năng (P3)"
description: "Phần 3: Cấu hình về Isolation Level - Read Committed Snapshot"
tags: sql configuration dba
---

> Nếu ứng dụng không nhất thiết phải lấy ra kết quả cực kỳ mới mỗi giây, 
> hạ level của Isolation trong SQL Server sẽ cải thiện hiệu năng rất đáng kể

Thông thường **Hạ Isolation Level** là kỹ thuật được nhắc đến đầu tiên khi phải xử lý các vấn đề liên quan đến ```Block/Deadlock```.

Để đảm bảo tính nhất quán/toàn vẹn của dữ liệu, SQLServer mặc định thiết lập chế độ Lock dữ liệu (.../Table/Row/Index/.../Page) khá nghiêm ngặt. Khi một tài nguyên đang được 1 Transaction chiếm khóa độc quyền (**X** lock) thì các transaction khác không thể đọc được tài nguyên này. Điều này dẫn đến các vấn đề Block/Deadlock. Cụ thể ta sẽ làm rõ ở một post khác chuyên về **Lock/Block/Deadlock**.

Dễ hiểu hơn đó là các câu query SELECT trên 1 dữ liệu buộc phải chờ các câu UPDATE/DELETE trên dữ liệu đó chạy xong (hoặc gần xong) mới có thể chạy và lấy về dữ liệu; hoặc các câu SELECT này không thể lấy về được dữ liệu luôn.

Phương án đẹp nhất luôn là phân được ```Read/Write``` transaction và route chúng vào các node khác nhau trong 1 Clustered Database. Kiến trúc ```AAG``` của SQLServer cho phép route như vậy. Tuy nhiên kỹ thuật này đòi hỏi thiết kế từ ban đầu phải chuẩn từ DB đến Code Backend. Hoặc nếu không cũng là 1 bigUpdate ở Backend để cung cấp các luồng ```ReadOnly``` hay ```ReadWrite``` riêng rẽ. 

Bởi vì việc App phải sử dụng thêm 1 Datasource ReadOnly song song với Datasource ReadWrite mặc định; các Service/Repository phải được chỉ rõ là đang sử dụng ReadOnly hay ReadWrite transaction; hay ở DB thực hiện Route ReadOnly chuẩn cho AAG;...đều tương đối phức tạp.

Vì vậy Hạ Isolation Level về **Read Committed Snapshot** là cách tương đối đơn giản và dễ áp dụng hơn. Kỹ thuật này cho phép SQLServer đánh version dữ liệu trong 1 DB và quản lý các version cũ của dữ liệu trong TempDB.

Điều này có nghĩa là các transaction có thể truy cập và lấy về tài nguyên ở version cũ hơn trong TempDB, thay vì chờ transaction khác nhả lock trên tài nguyên này.

Cũng đồng nghĩa với việc dữ liệu có thể không phải là mới nhất, tuy nhiên như từ đầu đã đề cập, nếu người dùng ứng dụng của bạn không nhất thiết phải sử dụng dữ liệu mới đến từng giây, thì đó là điều có thể chấp nhận được.

## Vậy hạ thì hạ như nào?

![image](/assets/meme/enough.png)

SQL Server có Isolation mặc định là **```READ COMMITED```**, và nó là một trong hệ thống các level sau:

![image](/assets/images/sqlperf-1-config-7.png)

Có thể thấy mặc định READ COMMITTED không cho phép ta đọc các dữ liệu _**Dirty**_ tức là các dữ liệu chưa được commit.

```READ COMMITTED SNAPSHOT``` là một phần của ```READ COMMITTED```, và là Isolation Level mặc định của **Azure SQL Database**. 
* Đương nhiên, do hỗ trợ đánh version và đọc từ TempDB, sử dụng Level ```READ COMMITTED SNAPSHOT``` cũng sẽ mất chi phí lưu trữ trên RAM/Disk dành cho TempDB.

### Action

Ta có thể set READ COMMITTED SNAPSHOT level cho DB như sau:

```sql
ALTER DATABASE MyDB SET READ_COMMITTED_SNAPSHOT ON
GO
```

Nhưng Microsoft lại không nói rằng, nếu không ngắt hết các session đang kết nối với DB, câu query SET trên sẽ chạy non-stop :))

Vì vậy chiến thuật đúng là:
* Chạy ở giờ thấp điểm của hệ thống.
* Ngắt ứng dụng đang sử dụng DB, và thực hiện SET level.

```sql
USE master
GO

/**
 * Cut off live connections
 * This will roll back any open transactions after 60 seconds and
 * restricts access to the DB to logins with sysadmin, dbcreator or
 * db_owner roles
 */
ALTER DATABASE MyDB SET RESTRICTED_USER WITH ROLLBACK AFTER 60 SECONDS
GO

-- Enable RCSI for MyDB
ALTER DATABASE MyDB SET READ_COMMITTED_SNAPSHOT ON
GO

-- Allow connections to be established once again
ALTER DATABASE MyDB SET MULTI_USER
GO

-- Check the status afterwards to make sure it worked
SELECT is_read_committed_snapshot_on
FROM sys.databases
WHERE [name] = 'MyDB'
```

Và kết quả thành công khi ta có như hình dưới, nó là kết quả của câu ```SELECT is_read_committed_snapshot_on...``` ở trên:

![image](/assets/images/sqlperf-1-config-8.png)

**Nếu chúng ta đang sử dụng AAG, ta phải thực hiện các query trên trên tất cả các Node trong cụm AAG.**

## Tham khảo

[https://docs.microsoft.com/en-us/sql/connect/jdbc/understanding-isolation-levels?view=sql-server-ver15](https://docs.microsoft.com/en-us/sql/connect/jdbc/understanding-isolation-levels?view=sql-server-ver15)

[https://willwarren.com/2015/10/12/sql-server-read-committed-snapshot/](https://willwarren.com/2015/10/12/sql-server-read-committed-snapshot/)

[https://www.brentozar.com/archive/2013/01/implementing-snapshot-or-read-committed-snapshot-isolation-in-sql-server-a-guide/](https://www.brentozar.com/archive/2013/01/implementing-snapshot-or-read-committed-snapshot-isolation-in-sql-server-a-guide/)