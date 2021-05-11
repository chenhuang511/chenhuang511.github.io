---
layout: post
title:  "In-Memory Optimized Table - Giải pháp tăng hiệu năng cho Temp Table"
description: "Một cách tăng hiệu năng và loại bỏ lock cho Temp/Variable Table"
tags: sql index temp-table in-memory-table dba
---

> Bài viết tập trung chủ yếu vào so sánh hiệu năng của Variable Table và InMemory Table
> Một ưu điểm vượt trội của InMemory Table là chống lock/latch sẽ không quá tập trung ở đây

## Về Temp/Variable Table

Chúng ta thường hay sử dụng nhất là Variable Table trong các Stored Procedure để lưu trữ tạm dữ liệu, phục vụ việc join hoặc để trả về dữ liệu đã tổng hợp.

```sql
DECLARE @LOCAL_TABLEVARIABLE TABLE
    (column_1 DATATYPE, 
     column_2 DATATYPE, 
     column_N DATATYPE
    )
```

Ví dụ trên là cách khai báo rất phổ biến. Ở đây có một số thông tin ta cần xem xét trong cách dùng này:

#### Table Variable được lưu trữ ở TempDB

Với việc được tạo và lưu trong TempDB, Variable Table rõ ràng lưu Schema và Data xuống Disk

#### Table Variable có phạm vi sử dụng (Scope) trong batch

Tức là không thể sử dụng Variable ở ngoài Stored mà nó được định nghĩa.

Đối với TempTable (là kiểu khai báo ```#MyTable``` hay ```##MyTable```), phạm vi sử dụng có thể nằm ngoài Batch (Procedure) mà nó được tạo.

Điều này cũng đồng nghĩa với việc **TableVariable định nghĩa ở Transaction A không thể được sử dụng trong Transaction B**.

#### Table Variable có thể tạo với Index đi kèm

Đây là cách **tăng hiệu năng đáng kể** khi SELECT/JOIN với Table Variable, thông thường các Dev hay bỏ qua tính năng rất quan trọng này.

```sql
DECLARE @TestTable TABLE
(
    Col1 INT NOT NULL PRIMARY KEY ,
    Col2 INT NOT NULL INDEX Cluster_I1 (Col1,Col2),
    Col3 INT NOT NULL UNIQUE
)
```

Như ví dụ trên ta có thể thấy, chúng ta có thể tạo CLUSTERED/NONCLUSTERED INDEX hay CONSTRAINT (NOT NULL/UNIQUE) với Table Variable.

* Với một đặc điểm là LifeTime của TableVariable chỉ tồn tại trong ExecutionTime của Batch, ta cũng không quá quan tâm về việc maintain index như thế nào.

#### Tuy hỗ trợ Index nhưng SQLServer không maintain Statistic của TableVariable

Đặc điểm này rất quan trọng để ta hiểu một vấn đề rằng:

* TableVariable chỉ dành cho các trường hợp mà dữ liệu nhỏ. Tức là khi ta dùng TableVariable lưu trữ lượng lớn dữ liệu, sẽ gây ra vấn đề về hiệu năng khi mà SQLServer không thể estimate gần đúng số row sẽ trả về, dẫn đến việc sử dụng các operator không chính xác trong ExecutionPlan.

Riêng vấn đề này hiện có rất nhiều giải pháp, điển hình là **SQLServer 2019** đã thêm tính năng dự đoán chuẩn xác số lượng row trả về -**Intelligent Query Processing (IQP)**) - cho TableVariable.

Hay chúng ta có thể dùng TempTable (```#MyTable``` hay ```##MyTable```) để thay thế TableVariable; hoặc nữa là sử dụng queryHint ```OPTION(RECOMPILE)```.

Tuy nhiên các phương án này cũng lại phải đối mặt với các vấn đề hiệu năng khác.

Có thể chúng ta đi sâu vào vấn đề này ở một bài viết khác.