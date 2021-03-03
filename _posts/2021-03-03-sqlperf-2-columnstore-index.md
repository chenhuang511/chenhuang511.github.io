---
layout: post
title:  "ColumnStore Index"
description: "loại index chuyên cho báo cáo và dataAnalyzing"
tags: sql index columnstore dba
---

## 0. Setup

Sử dụng setup cơ bản như ở bài viết [Setup ban đầu]({% post_url 2021-03-03-sqlperf-0-setup %})

Chúng ta cần tạo dữ liệu lớn từ CSDL sẵn có bằng cách chạy toàn bộ query như file dưới đây

[sqlperf-2-columnstore-make-big.sql](/assets/sql/sqlperf-2-columnstore-make-big.sql)

Bật hiển thị các thông số trả về khi query trên SSMS:

``` sql
set statistics io on;
set statistics time on;
```

## 1. Xét ví dụ sau

``` sql
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
SELECT bp.Name AS ProductName,
 COUNT(bth.ProductID),
 SUM(bth.Quantity),
 AVG(bth.ActualCost)
FROM dbo.bigProduct AS bp
 JOIN dbo.bigTransactionHistory AS bth
 ON bth.ProductID = bp.ProductID
GROUP BY bp.Name
OPTION (RECOMPILE);
```

Query plan và statistic khi query (Nhấn ```Ctrl+M``` ở SSMS trước khi Run query để có thông tin về queryPlan kèm theo):

![image](/assets/images/sqlperf-2-columnstore-1.png)

![image](/assets/images/sqlperf-2-columnstore-2.png)

Trong trường hợp này, bảng ```dbo.bigProduct``` có 25K row, bảng ```dbo.bigTransactionHistory``` có 31M row

1. Tổng thời gian query là 8s (7933ms)

2. Từ executionPlan ta thấy SQLServer phải scan tất cả các row của cả 2 bảng để lấy dữ liệu; đọc ```131888 page``` của bảng ```bigTransactionHistory``` và ```603 page``` của bảng ```bigProduct``` (cho phép JOIN) từ RAM.

* Vậy đâu là cách để tuning query này? Như các cách truyền thống thì gần như không có cách nào!

### Ta tuning bằng cách thêm index sau đây

```sql
CREATE NONCLUSTERED COLUMNSTORE INDEX ix_csTest
ON dbo.bigTransactionHistory
(
 ProductID,
 Quantity,
 ActualCost
);
```

Thực hiện lại query sau khi tạo Index và quan sát Stats & queryPlan:

![image](/assets/images/sqlperf-2-columnstore-3.png)

![image](/assets/images/sqlperf-2-columnstore-4.png)

1. Tổng thời gian query là **449ms (0.5s)**

2. Đọc ở bảng ```bigProduct``` là **622 page** (so với cũ là **603**) không khác nhau nhiều.

3. Đọc ở bảng ```bigTransactionHistory``` là **0** nhưng xuất hiện thêm thông tin mới: **Segment Reads = 33**

4. Quan trọng nhất là thời gian query đã giảm từ **8s** xuống **0.5s** tức là tăng **16 lần**.

Vậy rõ ràng **ColumnStore index** đã thể hiện vai trò cực kỳ hiệu quả trong trường hợp này

#### Ta có thể test thêm 1 trường hợp rất kinh điển

```sql
select count(*) from dbo.bigTransactionHistory;
```

![image](/assets/images/sqlperf-2-columnstore-5.png)

và sau đó ta thực hiện xóa ColumnStore index vừa tạo ở trên:

```sql
--drop index de test
DROP INDEX ix_csTest ON dbo.bigTransactionHistory;
```

Thực hiện lại ```SELECT COUNT(*)``` và xem kết quả:

![image](/assets/images/sqlperf-2-columnstore-6.png)

* Chênh lệch giữa việc có/không index là **7ms** và **831ms**; quá lớn!

## 2. Vậy tại sao ColumnStore Index lại ít phổ biến như vậy?

**ColumnStore Index** được giới thiệu từ bản 2012, tuy nhiên khi đó sử dụng ColumnStore Index cho 1 bảng, **chúng ta không thể update bảng đó, trừ khi remove Index này**. Điều này khiến cho ColumStore không thể sử dụng trên các hệ thống OLTP, tức là các hệ thống có dữ liệu update liên tục (như ta vẫn thường sử dụng).

* Hiểu nôm na là bảng mà có sẵn **PrimaryKey** thì không thể tạo ColumnStore Index được.

Tuy nhiên, bắt đầu từ bản SQLServer 2016, chúng ta đã có thể tạo **Nonclustered Columnstore Index** trên một OLTP table. **Đây chính là yếu tố thay đổi cuộc chơi**.

## 3. Lợi ích là rất lớn, tuy nhiên ta không nên dùng ColumnStore Index trong các trường hợp sau:

* Table có ít hơn **1M** row

Có quá ít row không tận dụng được lợi thế của ColumnStore Index so với các ảnh hưởng về Disk/CPU.

* Các cột cần đánh index có định dạng ```varchar(max)```, ```nvarchar(max)```, hay ```varbinary(max)```

Không tận dụng được các hàm tổng hợp SUM/AVG/…

Không đạt được lợi thế về nén dữ liệu khi thực hiện lưu trữ.

* Table rất thường xuyên update và delete, cụ thể là tỷ lệ thao tác (update + delete) lớn hơn **10%** trên tổng các thao tác (select + insert + select + update)

Update và Delete gây ra **fragmentation** (ta sẽ bàn sau về vấn đề này), quá nhiều fragmentation cho một index dẫn đến việc đọc dữ liệu kém hiệu quả (chậm hơn) và tốn tài nguyên lưu trữ (RAM và DISK)

Tuy nhiên khi áp dụng với các hệ thống đang chạy của công ty tôi, lưu lượng request về đêm là rất thấp; có thể áp dụng kỹ thuật chống Index Fragmentation là ```Rebuild/Reorganize Index```.

* Không sử dụng ColumnStore Index để truy vấn tìm kiếm như truyền thống; chỉ áp dụng cho các trường hợp tổng hợp dữ liệu (AVG/SUM/COUNT/MAX/MIN/…)

## 4. Một số thủ thuật hữu ích với ColumnStore Index

### 4.1. Thêm các trường liên quan đến query khi tạo index

```sql
--neu them dieu kien tu 1 cot nam ngoai columnstore index
select count(*) from dbo.bigTransactionHistory 
where Quantity < 75 and TransactionDate < '2006-01-01';
```

Ta drop index cũ và tạo index mới có chứa cả trường **```TransactionDate```**

```sql
--drop index de test
DROP INDEX ix_csTest ON dbo.bigTransactionHistory;

--tao columnstore index bao tat ca cac cot can query trong ca select/condition
CREATE NONCLUSTERED COLUMNSTORE INDEX ix_csTest_2
ON dbo.bigTransactionHistory(
 ProductID,
 Quantity,
 ActualCost,
 TransactionDate
);
```

Kết quả thu được khi query vẫn được tối ưu nhờ ColumnStore Index:

![image](/assets/images/sqlperf-2-columnstore-7.png)

### 4.2. Sử dụng điều kiện khi tạo ColumnStore index (Filtered Index)

Xét query:

```sql
--tuong tu them dieu kien voi query tren
SELECT bp.Name AS ProductName,
 COUNT(bth.ProductID),
 SUM(bth.Quantity),
 AVG(bth.ActualCost)
FROM dbo.bigProduct AS bp
 JOIN dbo.bigTransactionHistory AS bth
 ON bth.ProductID = bp.ProductID
WHERE bth.Quantity < 75
AND bth.TransactionDate < '2006-01-01'
GROUP BY bp.Name
OPTION (RECOMPILE);
```

Trường hợp này số lượng các row mà có ```TransactionDate``` có thể count ra là **6,9M**; do đó ta tạo ColumnStore với toàn bảng là **31M** thì không cần thiết.

```sql
--su dung filtered index cho columnstore index
DROP INDEX ix_csTest_2 ON dbo.bigTransactionHistory;

--tao lai index voi dieu kien loc
CREATE NONCLUSTERED COLUMNSTORE INDEX ix_csTest_2
ON dbo.bigTransactionHistory(
 ProductID,
 Quantity,
 ActualCost,
 TransactionDate
) WHERE TransactionDate < '2006-01-01';
```

Thực hiện lại query trên, ta vẫn đạt được mục đích

![image](/assets/images/sqlperf-2-columnstore-8.png)

## Tham khảo

[full sql của bài viết](/assets/sql/sqlperf-2-columnstore.sql)

Sách: **Apress.SQL.Server.2017.Query.Performance.Tuning.5th.Edition**

[https://www.red-gate.com/simple-talk/sql/sql-development/what-are-columnstore-indexes/](https://www.red-gate.com/simple-talk/sql/sql-development/what-are-columnstore-indexes/)

[https://www.red-gate.com/simple-talk/sql/sql-development/hands-on-with-columnstore-indexes-part-1-architecture/](https://www.red-gate.com/simple-talk/sql/sql-development/hands-on-with-columnstore-indexes-part-1-architecture/)

[https://docs.microsoft.com/en-us/sql/relational-databases/indexes/columnstore-indexes-design-guidance?view=sql-server-ver15](https://docs.microsoft.com/en-us/sql/relational-databases/indexes/columnstore-indexes-design-guidance?view=sql-server-ver15)

[https://docs.microsoft.com/en-us/sql/relational-databases/indexes/get-started-with-columnstore-for-real-time-operational-analytics?view=sql-server-2015](https://docs.microsoft.com/en-us/sql/relational-databases/indexes/get-started-with-columnstore-for-real-time-operational-analytics?view=sql-server-2015)
