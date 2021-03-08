---
layout: post
title:  "Các cấu hình cần thiết cho SQLServer để tăng hiệu năng (P1)"
description: "Phần 1: Cấu hình về Memory & Compression"
tags: sql configuration dba
---

> Một số cấu hình mặc định của SQL Server ta có thể chỉ kiểm tra chứ không set
- Các cấu hình được thao tác trên SQLServer 2017 và SSMS 18

## 1. Cấu hình cấp phát Memory cho SQLServer

Mục tiêu là **cấp phát nhiều nhất có thể** RAM của server cho SQLServer

```sql
sp_configure 'show advanced options', 1;
GO
RECONFIGURE;
GO
sp_configure 'max server memory', 2147483647;
GO
RECONFIGURE;
GO
```

**2147483647** là giá trị max có thể của SQLServer, theo đơn vị là MB.

Hoặc ta có thể cấu hình qua giao diện của SSMS

![image](/assets/images/sqlperf-1-config-1.png)

Với cấu hình này, SQLServer sẽ lấy nhiều nhất có thể RAM của máy chủ để dành cho Buffer của nó; do đó khi theo dõi Metric của máy chủ này sẽ thấy RAM luôn ở mức cao (> 80%)

Do đó để theo dõi máy chủ có thiếu RAM dành cho SQLServer hay không, **không thể xác định** bằng cách nhìn vào MemUsage của máy được. Kỹ thuật này ta sẽ bàn sau.

## 2. Cấu hình mở QueryStore

Hiểu nôm na **QueryStore** là chỗ để log lại các query đã chạy trong hệ thống, từ đó để có đầy đủ thông tin phục vụ cho quá trình Tuning Database hay để xử lý khi có lỗi xảy ra.

Bật **QueryStore** trong 1 khoảng thời gian, đủ dữ liệu để lấy làm đầu vào cho các quá trình tuning. Ví dụ như đầu vào cho công cụ **Database Engine Tuning Advisor** có sẵn trong bộ **SSMS** của Microsoft.

```sql
ALTER DATABASE [database] SET QUERY_STORE = ON;
```

Sau khi bật ta có thể thấy trong SSMS

![image](/assets/images/sqlperf-1-config-2.png)

Ta cũng có thể tắt QueryStore nếu không cần nữa

```sql
ALTER DATABASE [database] SET QUERY_STORE = OFF;
```

## 3. Kiểm tra & Cấu hình Compatibility Level

Hiểu nôm na **Compatibility Level** là các cấu hình, thuật toán,...mà Engine của SQLServer dùng cho từng DB. Các version khác nhau của SQLServer sẽ tương ứng với các CompatibilityLevel khác nhau.

![image](/assets/images/sqlperf-1-config-3.png)

Thường khi ta restore Database qua file **bak**, từ version SQLServer thấp lên version cao hơn, thì CompatibilityLevel vẫn ăn theo version cũ.
* Vậy nên không tận dụng được hết các lợi ích của version mới.

Kiểm tra CL hiện tại:

```sql
USE EASYBOOKS;  
GO  
SELECT compatibility_level  
FROM sys.databases WHERE name = 'EASYBOOKS';  
GO  
```

![image](/assets/images/sqlperf-1-config-4.png)

* Kết quả version hiện tại = 130, tức là theo version SQL Server 2016.

Thay đổi CL cho tương thích với Engine hiện tại (**SQLServer 2017**)

```sql
ALTER DATABASE EASYBOOKS  
SET COMPATIBILITY_LEVEL = 140;  
GO  
```

## Hết phần 1...