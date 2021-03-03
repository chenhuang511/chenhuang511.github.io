---
layout: post
title:  "KeyLookup & Covering Index"
description: "nâng cao hiệu năng của SQLServer bằng cách tối ưu chi phí trả về từ query"
tags: sql index key-lookup dba
---

> Chủ yếu tập trung tối ưu chi phí trả về dữ liệu khi thực hiện query với Nonclusterd Index.

## Setup

Sử dụng setup cơ bản như ở bài viết [Setup ban đầu]({% post_url 2021-03-03-sqlperf-0-setup %})

Bật hiển thị các thông số trả về khi query trên SSMS:

``` sql
set statistics io on;
set statistics time on;
```

## Xét ví dụ sau

``` sql
--select * gay ra keyLookup
SELECT *
FROM Sales.SalesOrderDetail AS sod
WHERE sod.ProductID = 776 
option (recompile);
```

các chỉ số & `execution plan`:

![image](/assets/images/sqlperf-2-1.png)

![image](/assets/images/sqlperf-2-2.png)

Có một vài kết luận:

1. 99% cost của query nằm ở bước keyLookup.
2. Có 1 indexSeek cho điều kiện ProductID, nghĩa là ProductID được đánh index (NonClustered Index).
3. Có 228 row trả về.
4. Có 1297 logicalReads, tức là đọc 1297 page từ buffer của SQLServer.

## Xét tiếp ví dụ thứ 2

``` sql
--select rieng productID
SELECT sod.ProductID
FROM Sales.SalesOrderDetail AS sod
WHERE sod.ProductID = 776
option (recompile);
```

![image](/assets/images/sqlperf-2-3.png)

![image](/assets/images/sqlperf-2-4.png)

Đã có khác biệt so với query trước đó và ta thấy rằng: 

1. Vẫn có IndexSeek với ProductID như ở plan trước nhưng không còn bước keyLookup trong plan.
2. Có 228 row trả về.
3. Có 2 logicalReads, tức là chỉ có 2 page đọc từ buffer của SQLServer.

* Vậy ta thấy khác biệt rất lớn ở 2 query, vẫn trả về 228 row nhưng đọc dữ liệu là 1297 so với 2.
* Khác nhau ở 2 query là ``` SELECT * ``` và ``` SELECT sod.ProductID ``` từ đó dẫn đến 2 plan khác nhau: Có keyLookup và không có keyLookup.
* KeyLookup là quá trình SQLServer phải loop trong Clustered Index để lấy dữ liệu trả về.

### Ở plan 1

Sau khi seek trong NonClustered Index, bước tiếp là phải loop trong ClusteredIndex để lấy ra tất cả các cột của row

![image](/assets/images/sqlperf-2-5.png)

Như hình trên, có ```228 lần execution```, mỗi lần lấy về ```1 row```.

* Vậy rõ ràng KeyLookup gây ra chi phí lớn cho câu query này.
* Và việc ```SELECT *``` là nguyên nhân gây ra KeyLookup ở query 1.

## Xét tiếp ví dụ 3

``` sql
--khong select * van gay ra keyLookup
SELECT sod.ProductID, sod.CarrierTrackingNumber
FROM Sales.SalesOrderDetail AS sod
WHERE sod.ProductID = 776
option (recompile);
```

![image](/assets/images/sqlperf-2-6.png)

![image](/assets/images/sqlperf-2-7.png)

Thêm ```CarrierTrackingNumber``` vào ```SELECT``` để trả về, và KeyLookup đã xuất hiện trở lại.

SqlServer phải đọc 709 page từ buffer.

* Vậy tức là không phải chỉ SELECT * gây ra keyLookup, mà những cột không có NonClustered Index sẽ bắt buộc SQLServer phải scan trong ClusterIndex để lấy ra dữ liệu.

## Sửa NonclusterIndex để loại bỏ KeyLookup

``` sql
--sua nonclusteredIndex 
CREATE INDEX idx_SalesOrderDetail_ProductID_CarrierTrackingNumber 
ON Sales.SalesOrderDetail (ProductID, CarrierTrackingNumber);
```

Thực hiện lại query 3

![image](/assets/images/sqlperf-2-8.png)

![image](/assets/images/sqlperf-2-9.png)

* Ta đạt được mục đích là KeyLookup đã biến mất, số page đọc từ buffer cũng chỉ còn 5.
* Tuy nhiên trong trường hợp này, thêm một cột vào INDEX tức là tăng chi phí maintain; và trong trường hợp có nhiều hơn 2 cột cần trả về thì tức là INDEX sẽ trở nên phức tạp hơn. Khi đó COVERING INDEX sẽ có nhiều ưu điểm hơn.

## Sử dụng Covering Index để loại bỏ KeyLookup

``` sql
--tao Covering Index
CREATE INDEX idx_SalesOrderDetail_ProductID_CarrierTrackingNumber 
ON Sales.SalesOrderDetail (ProductID) 
INCLUDE (CarrierTrackingNumber)
WITH DROP_EXISTING;
```

Chạy lại query3, ta thấy vẫn đạt được kết quả như khi ta mở rộng trường ở Index

![image](/assets/images/sqlperf-2-10.png)

![image](/assets/images/sqlperf-2-11.png)

1. IndexSeek và chỉ phải read 5 pages từ buffer của SQLServer.
2. Dữ liệu INCLUDE được lưu ở leafPage trong cấu trúc của chính NonClustered Index đó, do đó không cần thêm bước lookup để lấy dữ liệu từ ClusteredIndex từ SQLServer (như hình dưới đây).

![image](/assets/images/sqlperf-2-12.png)

* Covering Index có thể dùng để tạo cho nhiều Column, tuy nhiên số lượng Column mà Index đó cover phải được tính toán hợp lý, vì có thể chi phí maintain sẽ quá cả chi phí query do keyLookup gây ra.
* Khi xét 1 query cần đánh INCLUDE, tính toán số lần chạy của query đó (so với tương quan toàn query) dựa vào QueryStore, nếu query chạy nhiều lần mà chưa có INCLUDE, khi đó nên thêm.

## Tham khảo

[Full sql trong bài viết](/assets/sql/sqlperf-2-covering-index.sql)

[https://www.mssqltips.com/sqlservertutorial/258/eliminating-bookmark-keyrid-lookups/](https://www.mssqltips.com/sqlservertutorial/258/eliminating-bookmark-keyrid-lookups/)

[https://www.brentozar.com/blitzcache/expensive-key-lookups/](https://www.brentozar.com/blitzcache/expensive-key-lookups/)