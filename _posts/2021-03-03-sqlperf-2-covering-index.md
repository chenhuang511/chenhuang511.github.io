---
layout: post
title:  "KeyLookup & Covering Index"
description: "một kỹ thuật nâng cao hiệu năng của SQLServer bằng cách loại bỏ KeyLookup"
tags: sql performance index
---
Chủ yếu tập trung tối ưu chi phí trả về dữ liệu khi thực hiện query với Nonclusterd Index.

## Setup

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

* 99% cost của query nằm ở bước keyLookup
* Có 1 indexSeek cho điều kiện ProductID, nghĩa là ProductID được đánh index (NonClustered Index)
* Có 228 row trả về
* Có 1297 logicalReads, tức là đọc 1297 page từ buffer của SQLServer

## Xét tiếp ví dụ thứ 2

``` sql
--select rieng productID
SELECT sod.ProductID
FROM Sales.SalesOrderDetail AS sod
WHERE sod.ProductID = 776
option (recompile);
```

