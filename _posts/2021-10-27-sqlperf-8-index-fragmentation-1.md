---
layout: post
title:  "Index Fragmentation và cách xử lý (P1)"
description: "Phần 1: Lý thuyết về phân mảnh dữ liệu, phương án xử lý và thực thi"
tags: sql index fragmentation
---

## Lý thuyết về Index Fragmentation (IF)

### Định nghĩa

Là khi dữ liệu (các pages) index trong DB bị phân mảnh, dẫn đến máy chủ tốn tài nguyên về DISK/RAM để lưu trữ, đồng thời IF cũng gây ra vấn đề là các page dữ liệu không liền mạch khiến máy chủ mất nhiều tài nguyên CPU hơn để đọc dữ liệu.

IF là một vấn đề hiệu năng thường xuyên gặp ở OLTP DB, nhưng cũng không khó để xử lý.

Dữ liệu Index ở SQLServer được tổ chức ở dạng B-TREE, và IF xảy ra ở node lá.

### Nguyên nhân xảy ra

IF xảy ra khi dữ liệu được thêm mới/chỉnh sửa (INSERT/UPDATE) dữ liệu vào Table.

Tuy nhiên DELETE lại không giúp giảm IF bởi vì đơn giản nó chỉ xóa bỏ những dữ liệu trên các page đã phân mảnh trước đó rồi.

Ở các DB OLTP (là các DB thông thường sử dụng, không phải DB để phân tích, tổng hợp dữ liệu) việc INSERT/UPDATE là thường xuyên, do đó IF cũng là vấn đề thường xuyên xảy ra.

### Ví dụ về Index Fragmentation

* Giả sử 1 index có 9 giá trị (9 rows) và size trung bình mỗi row là gần 2KB,
* Vì mỗi Page chỉ chứa tối đa 8KB, do đó giả sử ở trường hợp này, mỗi page chứa 4 row giá trị của Index.
* Ở SQLServer, mỗi page chứa thông tin liên kết (link) giữa các page trước và sau nó; mục đích là để đảm bảo có thể sắp xếp các page. Kiểu sắp xếp dữ liệu page này được gọi là logical order.

![image](/assets/images/sqlperf-8-1.png)

* Với dữ liệu Index (indexRow) đã được sắp xếp như trên, vấn đề phát sinh là cần insert 1 row mới có giá trị là 25.
* Để đảm bảo logic, row 25 sẽ được thêm vào giữa 20 và 30; nhưng hiện tại node lá này đã full row, dẫn đến việc phải phân mảnh dữ liệu ở node. Và một node lá mới sẽ được cấp phát cho index này, sau đó một phần dữ liệu của node lá đầu tiên (10-40) sẽ được chuyển sang node lá mới.
* Song song với việc chuyển dữ liệu sang node mới, liên kết giữa các node lá cũng sẽ được cập nhật để đảm bảo logical order.

![image](/assets/images/sqlperf-8-2.png)

* Tuy logical order vẫn được đảm bảo qua việc cập nhật link, nhưng như chúng ta thấy, vể mặt vật lý các row dữ liệu không được sắp xếp liên tiếp, tức là physical order không được đảm bảo.

### Vậy sự phân mảnh này ảnh hưởng thế nào đến việc đọc dữ liệu của SQL Server?

Ta đã thấy khi sự phân mảnh xảy ra, SQL Server sẽ phải tốn thêm tài nguyên để cấp phát và lưu trữ row dữ liệu mới. Bây giờ ta sẽ xem xét đến cách mà SQL Server phải tốn thêm tài nguyên để đọc khi dữ liệu index đã bị phân mảnh.

SQLServer gộp 8 pages (8 index rows) thành một đơn vị mới gọi là extent và sử dụng extent là đơn vị vật lý nhỏ nhất khi lưu trữ xuống disk. Và điều kiện lý tưởng nhất khi lưu xuống đĩa đó là thứ tự sắp xếp trong các extent (physical order) trùng với thứ tự được đảm bảo bởi liên kết trên memory (logical order). Khi đó, số lần mà SQLServer phải luân chuyển để đọc dữ liệu trong extent là tối thiểu.

![image](/assets/images/sqlperf-8-3.png)

Nhưng khi IF xảy ra, physical order không còn được đảm bảo, vì vậy giả sử cần đọc các row dữ liệu có giá trị từ **20 – 40**; SQLServer sẽ phải switch giữa 2 extent 1 và 2 như ở hình trên. Đây chính là chi phí tài nguyên CPU khi đọc dữ liệu trong trường hợp có IF.

Và ví dụ nếu phải lấy ra các index row có giá trị từ **25 – 90**, cần 3 lần switch như sau:

* Lần đầu switch là để lấy giá trị **30**, sau khi lấy xong **25**; 
* Lần switch thứ 2 là để lấy giá trị **50**, sau khi lấy xong **40**; 
* Lần switch thứ 3 là để lấy giá trị **90**, sau khi lấy xong **80**.

Tình huống phân mảnh dữ liệu giữa các node như trên được gọi là **External Fragmentation**.

Ngoài ra, khi IF xảy ra, ta có thể thấy ở ví dụ trên, node lá đầu tiên sẽ thừa ra space. Cơ chế này cũng xảy ra tương tự khi chúng ta thực hiện **DELETE** dữ liệu. Tình huống này gọi là **Internal Fragmentation** vì nó xảy ra trong 1 node.

## Phương án xử lý Index Fragmentation

### Kiểm tra tình trạng phân mảnh trong DB

SQLServer cung cấp sẵn DMV để ta có thể truy vấn tình trạng phân mảnh dữ liệu của từng Index trong toàn bộ DB:

```sql
SELECT S.name as 'Schema',
       T.name as 'Table',
       I.name as 'Index',
       DDIPS.avg_fragmentation_in_percent,
       DDIPS.page_count
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, NULL) AS DDIPS
         INNER JOIN sys.tables T on T.object_id = DDIPS.object_id
         INNER JOIN sys.schemas S on T.schema_id = S.schema_id
         INNER JOIN sys.indexes I ON I.object_id = DDIPS.object_id
    AND DDIPS.index_id = I.index_id
WHERE DDIPS.database_id = DB_ID()
  and I.name is not null
  AND DDIPS.avg_fragmentation_in_percent > 0
ORDER BY DDIPS.avg_fragmentation_in_percent desc
```

![image](/assets/images/2021-10-28-sqlperf-8-3.png)

* ```avg_fragmentation_in_percent```: % dữ liệu bị phân mảnh của 1 index;
* ```page_count```: số lượng page dữ liệu của index.

### Phương án xử lý

* Dựa vào trạng thái Fragmentation của từng index trong từng table ở DB để quyết định Phương án xử lý;
* Không xử lý với các Index có ```page_count``` < **100**
* Thực hiện REBUILD INDEX với các Index có ngưỡng ```avg_fragmentation_in_percent``` > **70%**;
* Thực hiện REORGANIZE INDEX với các Index có ngưỡng ```avg_fragmentation_in_percent``` từ **30 – 70%**;
* Bởi vì việc REBUILD INDEX gây ảnh hưởng khá lớn đến hiệu năng, và có lock dữ liệu khi xử lý; do đó việc thực hiện maintain index này nên được thực hiện trong thời gian **“peek time”** của hệ thống, ví dụ như vào cuối tuần.

### Có nhiều cách để Implement phương án xử lý trên, phần tiếp theo chúng ta dùng Stored Procedure và Cron Job với NodeJS để thực thi...

## Tham khảo

Sách: **Apress.SQL.Server.2017.Query.Performance.Tuning.5th.Edition**

[https://www.brentozar.com/archive/2013/09/index-maintenance-sql-server-rebuild-reorganize/](https://www.brentozar.com/archive/2013/09/index-maintenance-sql-server-rebuild-reorganize/)

[https://www.sqlshack.com/how-to-identify-and-resolve-sql-server-index-fragmentation/](https://www.sqlshack.com/how-to-identify-and-resolve-sql-server-index-fragmentation/)