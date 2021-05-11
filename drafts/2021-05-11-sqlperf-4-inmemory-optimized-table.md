---
layout: post title:  "In-Memory Optimized Table - Giải pháp tăng hiệu năng cho Temp Table"
description: "Một cách tăng hiệu năng và loại bỏ lock cho Temp/Variable Table"
tags: sql index temp-table in-memory-table dba
---

> Bài viết tập trung chủ yếu vào so sánh hiệu năng của Variable Table và InMemory Table
> Một ưu điểm vượt trội của InMemory Table là chống lock/latch sẽ không quá tập trung ở đây

## Về Temp/Variable Table

Chúng ta thường hay sử dụng nhất là Variable Table trong các Stored Procedure để lưu trữ tạm dữ liệu, phục vụ việc join
hoặc để trả về dữ liệu đã tổng hợp.

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

Đối với TempTable (là kiểu khai báo ```#MyTable``` hay ```##MyTable```), phạm vi sử dụng có thể nằm ngoài Batch (
Procedure) mà nó được tạo.

Điều này cũng đồng nghĩa với việc **TableVariable định nghĩa ở Transaction A không thể được sử dụng trong Transaction
B**.

#### Table Variable có thể tạo với Index đi kèm

Đây là cách **tăng hiệu năng đáng kể** khi SELECT/JOIN với Table Variable, thông thường các Dev hay bỏ qua tính năng rất
quan trọng này.

```sql
DECLARE @TestTable TABLE
(
    Col1 INT NOT NULL PRIMARY KEY ,
    Col2 INT NOT NULL INDEX Cluster_I1 (Col1,Col2),
    Col3 INT NOT NULL UNIQUE
)
```

Như ví dụ trên ta có thể thấy, chúng ta có thể tạo CLUSTERED/NONCLUSTERED INDEX hay CONSTRAINT (NOT NULL/UNIQUE) với
Table Variable.

* Với một đặc điểm là LifeTime của TableVariable chỉ tồn tại trong ExecutionTime của Batch, ta cũng không quá quan tâm
  về việc maintain index như thế nào.

#### Tuy hỗ trợ Index nhưng SQLServer không maintain Statistic của TableVariable

Đặc điểm này rất quan trọng để ta hiểu một vấn đề rằng:

* TableVariable chỉ dành cho các trường hợp mà dữ liệu nhỏ. Tức là khi ta dùng TableVariable lưu trữ lượng lớn dữ liệu,
  sẽ gây ra vấn đề về hiệu năng khi mà SQLServer không thể estimate gần đúng số row sẽ trả về, dẫn đến việc sử dụng các
  operator không chính xác trong ExecutionPlan.

Riêng vấn đề này hiện có rất nhiều giải pháp, điển hình là **SQLServer 2019** đã thêm tính năng dự đoán chuẩn xác số
lượng row trả về -**Intelligent Query Processing (IQP)**) - cho TableVariable.

Hay chúng ta có thể dùng TempTable (```#MyTable``` hay ```##MyTable```) để thay thế TableVariable; hoặc nữa là sử dụng
queryHint ```OPTION(RECOMPILE)```.

Tuy nhiên các phương án này cũng lại phải đối mặt với các vấn đề hiệu năng khác.

Có thể chúng ta đi sâu vào vấn đề này ở một bài viết khác.

## In-Memory Optimized Table

Như ta biết ở trên thì TempTable hay TableVariable đều lưu trữ dữ liệu ở Disk.

Và vì thế để nâng cao hiệu năng, ta có thể hình dung tới một giải pháp cho phép sử dụng các loại Table này ở RAM/Memory.

Và giải pháp đó là **In-Memory Optimized Table**, được cung cấp ở SQLServer bắt đầu từ version 2014.

#### Các đặc điểm cơ bản của In-Memory Optimized Table (IMOT)

* Các dữ liệu của IMOT được lưu hoàn toàn ở Memory. Tuy nhiên SQLServer vẫn lưu cả Data/Log xuống đĩa để đảm bảo tính
  Durability (ACID) của dữ liệu.
* Không đọc/ghi dữ liệu vào TempDB, tính toán hoàn toàn trên Memory.
* Có 2 option cho việc ghi dữ liệu xuống Disk (như đã nói ở trên): **SCHEMA_ONLY** & **SCHEMA_AND_DATA**
* Yêu cầu thêm phần cứng (Disk/RAM) để lưu dữ liệu.
* Yêu cầu có **ít nhất 1 INDEX** khi tạo Table. Hỗ trợ 2 loại Index là HASH và NONCLUSTERED.

> Ở đây ta tập trung vào việc chuyển đổi từ TableVariable sang InMemory Table
> Bỏ qua việc thay thế/so sánh giữa TempTable và InMemory Table

#### Điều kiện tiên quyết để sử dụng IMOT

Để đảm bảo tính Durability (một phần của ACID): Một khi transaction đã commit, DB phải đảm bảo là nó đã commit (ghi log,
ghi data xuống đĩa);

* Điểm khác biệt với Table bình thường đó là với IMOT, khi transaction đã commit, vẫn có thể mất Data trong trường hợp
  ta chỉ ghi Log (SHEMA_ONLY)

Ta bắt buộc PHẢI cung cấp một FILEGROUP mới cho IMOT. Đây chính là chi phí phát sinh trên Disk:

```sql
ALTER DATABASE EASYBOOKS
    ADD FILEGROUP EasyBooks_InMemoryData
        CONTAINS MEMORY_OPTIMIZED_DATA;
GO
ALTER DATABASE EASYBOOKS
    ADD FILE (NAME = 'EasyBooks_InMemoryData',
        FILENAME = 'D:\Data\EasyBooks_InMemoryData.ndf')
        TO FILEGROUP EasyBooks_InMemoryData;
GO
```

Từ đây ta mới có thể tạo InMemory Optimized Table.

#### Chuyển đổi Table Variable sang InMemory Optimized Table

```sql
DECLARE @tvTableD TABLE  
    ( Column1   INT   NOT NULL ,  
      Column2   CHAR(10) );
```

Kiểu khai báo truyền thống như trên không hỗ trợ InMemory Optimized. Thay vào đó ta thay đổi cú pháp như sau, và có thể
chỉ cho SQLServer nó là IMOT:

```sql
CREATE TYPE dbo.typeTableD  
    AS TABLE  
    (  
        Column1  INT   NOT NULL   INDEX ix1,  
        Column2  CHAR(10)  
    )  
    WITH  
        (MEMORY_OPTIMIZED = ON)
```

Như trên ta thấy, IMOT cần một INDEX, trong trường hợp này ```ix1``` là NONCLUSTERED INDEX.

## Đánh giá hiệu năng để thấy ưu điểm của việc chuyển đổi

Kịch bản thực hiện như sau trên cả TableVariable và InMemory Optimized Table:

* Tạo bảng và INSERT 1000 ROWS.
* DELETE 100 ROWS.
* SELECT ra tất cả các ROW còn lại.

```mermaid
graph LR;
    A[Create Table] --> B[Insert 1000 Rows] --> C[Delete 100 rows] --> D[Select All]
```

Ở mỗi phương án, ta in ra thời gian thực hiện Batch, bởi vì với IMOT không có thông tin tổng thời gian kể cả ta bật ```STATISTIC TIME```

