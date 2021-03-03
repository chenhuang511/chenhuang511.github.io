---
layout: post
title:  "ColumnStore Index"
description: "loại index chuyên cho báo cáo và dataAnalyzing"
tags: sql index columnstore dba
---

## Setup

Sử dụng setup cơ bản như ở bài viết [Setup ban đầu]({% post_url 2021-03-03-sqlperf-0-setup %})

Chúng ta cần tạo dữ liệu lớn từ CSDL sẵn có bằng cách chạy toàn bộ query như file dưới đây

[sqlperf-2-columnstore-make-big.sql](/assets/sql/sqlperf-2-columnstore-make-big.sql)

Bật hiển thị các thông số trả về khi query trên SSMS:

``` sql
set statistics io on;
set statistics time on;
```