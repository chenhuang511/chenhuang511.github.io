---
layout: post
title:  "Ngữ cảnh sử dụng TableVariable và TempTable"
description: "Sử dụng đúng cách các loại bảng tạm"
tags: sql temp-table
---

## Cách sử dụng Index

### @Table chỉ tạo được in-line, #Table tạo được split

```sql
--với @Table
DECLARE @table_variable TABLE (
   column_1 INT NOT NULL PRIMARY KEY,
   column_2 VARCHAR(50) INDEX idx
);

--với #Table
CREATE TABLE #temp_table (
   column_1 INT NOT NULL PRIMARY KEY,
   column_2 VARCHAR(50)
)
CREATE NONCLUSTERED INDEX idx1 ON #temp_table(column_2)
```

### #Table sử dụng được nhiều loại index

```sql
--tổ hợp index
CREATE NONCLUSTERED INDEX idx2 ON #temp_table(column_2, column_3)

--covering index
CREATE NONCLUSTERED INDEX idx3 ON #temp_table (column_2) INCLUDE (column_3)

--filtered index
CREATE NONCLUSTERED INDEX idx4 ON #temp_table (column_2) WHERE column_3 = 'VN'

--columnstore index
CREATE NONCLUSTERED COLUMNSTORE INDEX cidx5 ON #temp_table (column_2)
```

Các loại index trên, #Table tạo và sử dụng như một Table bình thường. Tuy nhiên @Table không thể tạo được các index này.

Do đó, đây cũng là nhược điểm của @Table so với #Table, trong trường hợp ta cần sử dụng các loại index này, nên dùng #Table.

Đặc biệt với Columnstore index, nếu query batch cần tổng hợp dữ liệu với các hàm MAX, MIN, COUNT, SUM, AVG thì sẽ mang lại hiệu năng vượt trội so với Row-Index thông thường.

[Tham khảo thêm về Columnstore index]({% post_url 2021-03-03-sqlperf-2-columnstore-index %})

## Về maintain Statistíc

Table Variable (@Table) không maintain Statistics

Temp Table (#Table) thì có maintain Statistics

Trước bản SQLServer 2019, @Table luôn dự đoán số row trả về = 1, điều này khiến việc đưa ra queryPlan sai nếu dự đoán lệch quá nhiều so với thực tế, và sẽ gây ra vấn đề lớn về hiệu năng.

```sql
-- Table variable luôn dự đoán số row = 1
DECLARE @tablevariable TABLE
  (
      customerid    [int]      NOT NULL PRIMARY KEY,
      lastorderdate [datetime] NULL
  );

INSERT INTO @tablevariable
SELECT customerid, max(orderdate) lastorderdate
FROM sales.SalesOrderHeader
GROUP BY customerid;

SELECT *
from sales.salesorderheader soh
        INNER JOIN @tablevariable t
            ON soh.customerid = t.customerid 
AND soh.orderdate = t.lastorderdate
GO
```

![image](/assets/images/sqlperf-7-1.png)

TempTable maintain statistics như một table bình thường, có đầy đủ các thông tin:

```sql
DBCC SHOW_STATISTICS ('tempdb..#temp_table', 'id')
```

Tuy nhiên việc maintain statistics cũng khiến các query với TempTable có thể gây ra Query Recompilation.

## So sánh 2 loại khi UPDATE và DELETE

Hiệu năng của #Table sẽ tốt hơn @Table khi @Table nếu số lượng item cần Update/Delete là lớn.

Ngược lại nếu số lượng item bé, @Table hoạt động tốt hơn.

Thử nghiệm với 1M bản ghi, so với @tableVariable:

* tempTable UPDATE nhanh hơn 6 lần
* tempTable DELETE nhanh hơn 8 lần

```sql
DECLARE @T TABLE(id INT PRIMARY KEY, Flag BIT);

CREATE TABLE #T (id INT PRIMARY KEY, Flag BIT);

INSERT INTO @T
output inserted.* into #T
SELECT TOP 1000000 ROW_NUMBER() OVER (ORDER BY @@SPID), 0
FROM master..spt_values v1, master..spt_values v2

SET STATISTICS TIME ON

/* CPU time = 5391 ms,  elapsed time = 6514 ms.*/
UPDATE @T SET Flag=1;

/*CPU time = 5469 ms,  elapsed time = 6086 ms.*/
DELETE FROM @T

/* CPU time = 922 ms,  elapsed time = 1014 ms.*/
UPDATE #T SET Flag=1;

/*CPU time = 687 ms,  elapsed time = 779 ms.*/
DELETE FROM #T

DROP TABLE #T
```

## Nên dùng #tempTable khi

Nếu cần đến các loại index đặc biệt Covering Index (INCLUDE), Columnstore Index

Nếu số lượng bản ghi insert vào là lớn (> 5K rows)

Dữ liệu Insert vào table qua nhiều bước trong 1 Proc: mỗi lần insert, #tempTable sẽ cập nhật Statistics và sử dụng các Plan thích hợp ở mỗi bước

Nếu trong Proc cần Update/Delete với số lượng lớn dữ liệu

## Nên dùng @tableVariable

Tập dữ liệu cần xử lý nhỏ < 5K rows

Query hay Proc có LOCK đi kèm: vì @table đi theo từng query/batch, do đó sẽ không bị LOCK/DEADLOCK như #table, khi mà 1 session có thể có nhiều query cùng tham chiếu đến 1 Table

## Nên dùng In-Memory Optimized Table trong trường hợp dữ liệu lớn nếu có thể

[Bài vể In-Mem Optimized Table ]({% post_url 2021-05-11-sqlperf-4-inmemory-optimized-table %})