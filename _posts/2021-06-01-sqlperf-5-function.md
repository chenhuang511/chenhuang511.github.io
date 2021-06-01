---
layout: post
title:  "Tối ưu hiệu năng bằng cách sử dụng Function đúng cách"
description: "Các cách sử dụng Function trong SQL Server trong các tình huống"
tags: sql function dba
---

## 1. Về function của SQL Server

Điều đầu tiên cần lưu ý ở đây là:

> Bản thân Function không giúp tăng hiệu năng truy vấn, chúng ta sử dụng function để tiện cho việc viết truy vấn, vì khả năng tái sử dụng của Function.

Do đó, ta chỉ nên tạo Function khi các tác vụ trong function thường xuyên được tái sử dụng (trong nhiều Stored Procedure chằng hạn)

Có 3 loại Function trong Sql Server: ```Scalar Function```, ```Inline Table-Valued Function (iTVF)``` và ```Multiple Statements Table-Valued Function (MSTVF)```

### 1.1. Scalar Function

Là loại function trả về một biểu thức, tức là kiểu dữ liệu trả về là Data_Type (INT, VARCHAR, DEC, DATE,...).

```sql
CREATE FUNCTION AddTwoNumbers
(
    @a INT,
    @b INT,
)
RETURNS INT
WITH SCHEMABINDING
AS 
BEGIN
    RETURN @a + @b;
END;
```

Như trong function trên, ta tính tổng của 2 số, trả về kiểu INT, và giá trị trả về là 1 biểu thức:

```sql
RETURN @a + @b;
```

### 1.2. Inline Table-valued Function (iTVF)

iTVF sẽ trả về một bảng dữ liệu (Table-Valued) và dữ liệu đó là kết quả của **MỘT câu SELECT**

Tức là thân function chỉ có duy nhất 1 SELECT, không hơn.

```sql
CREATE FUNCTION GetCompanyByTaxCode(@taxcode VARCHAR(14))
    RETURNS TABLE
        WITH SCHEMABINDING
        AS RETURN
        SELECT Name, Taxcode
        FROM Company c
        WHERE c.taxcode = @taxcode
```

```RETURN TABLE``` chỉ ra đây là Table-Valued Function. Và trong thân Function trên chỉ có duy nhất một câu SELECT.

### 1.3. Multiple Statements Table-Valued Function (MSTVF)

MSTVF cũng trả về một bảng dữ liệu (Table-Valued) nhưng trong thân Function sẽ có nhiều hơn một câu truy vấn.

```sql
CREATE FUNCTION GetCompanyByTaxCodeWithLog(@taxcode VARCHAR(14), @userId INT)
    RETURNS @result TABLE
                    (
                        Name    NVARCHAR(200),
                        Taxcode VARCHAR(14),
                        LogID   INT
                    )
    WITH SCHEMABINDING
AS
BEGIN
    INSERT INTO DataLog (UserID) VALUES (@userId);

    DECLARE @LogID INT;
    SET @LogID = (SELECT SCOPE_IDENTITY());

    DECLARE @Name NVARCHAR(200), @Code VARCHAR(14);
    SELECT @Name = Name, @Code = Taxcode
    FROM Company c
    WHERE c.taxcode = @taxcode;

    INSERT INTO @result(Name, Taxcode, LogID) VALUES (@Name, @Code, @LogID);
    RETURN
END
```

Như trên, bên trong thân Function của MSTVF, ta sử dụng một loạt các truy vấn để cuối cùng trả về một Table-Variable ```@result```.

## 2. Các vấn đề hiệu năng với Function

Bởi vì iTVF chỉ có duy nhất một query SELECT trong logic code, do đó SQL Server sẽ đưa nó ra ngoài và APPLY vào query chính. 
Ví dụ ta đang dùng iTVF ở trong 1 Procedure, SQL Server coi câu SELECT ở iTVF như một phần của Procedure đó (SELECT, JOIN, APPLY,...).
*  Điều này giúp SQlServer có thể sử dụng Statistics, Parallelism với iTVF.

Scalar Function và MSTVF đều cho phép sử dụng nhiều truy vấn bên trong thân Function, do đó SQL Server không coi nó là 1 phần code của truy vấn bọc bên ngoài (như ví dụ Procedure ở trên)
* Và do đó, Statistics, Parallelism không áp dụng cho 2 loại Function này, hoặc là hạn chế hơn.

Một ví dụ về Statistics với MSTVF:
* Trước v2016, SQLServer luôn ước lượng số bản ghi trả về là 1 (tù vãi chày)
* Bản 2016, SQLServer fix luôn có 100 bản ghi trả về khi estimate.
* Bản 2017, SQLServer update lớn cho MSTVF khi tính toán số bản ghi sẽ trả về (như sử dụng Statistics)

Với Scalar Function, SQLServer 2019 có bigUpdate dành cho loại Function này, đó là ngầm chuyển ScalarFunction về iTVF, do đó cải thiện hiệu năng rất nhiều so với các bản trước đó.

Do đó ta có thể thấy hiệu năng của iTVF là tốt nhất trong 3 loại Function này.

## 3. Các phương pháp tăng hiệu năng với Function

### 3.3. Sử dụng bản SQLServer mới nhất nếu có thể

Rõ ràng, nếu có thể ta sử dụng bản 2019, update đầy đủ.

### 3.2. Không sử dụng Function nếu không cần thiết

Như đã nói, mục tiêu của Function chỉ là tính tiện dụng, tái sử dụng khi lập trình.

Do đó, nếu không cần tái sử dụng trong nhiều logic code khác nhau, chúng ta không cần thiết tạo Function.

### 3.3. Sử dụng inline Table-Valued Function (iTVF) nếu có thể

iTVF như một phần của query bao bên ngoài, có thể sử dụng Statistics, tính toán song song Parallelism, do đó luôn có thể optimize với loại Function này.

Khi định nghĩa Scalar Function hay MSTVF, luôn xem xét kỹ lưỡng liệu ta có thể sử dụng iTVF hay không.

### 3.4. Sử dụng trick để loại bỏ Parameter Sniffing khi gặp vấn đề hiệu năng với Scalar Function/MSTVF

Đầu tiên, như đề cập ở 3.3, ta hạn chế sử dụng 2 loại này, vì chúng thường gây ra vấn đề hiệu năng, và phần lớn là rất tệ.

Để xem xét chính xác vấn đề hiệu năng với Scalar Function/MSTVF là một công việc rất phức tạp.

Một vấn đề phổ biến trong trường hợp này là [Parameter Sniffing (Đánh hơi tham số)](https://blog.sqlauthority.com/2019/12/19/sql-server-parameter-sniffing-simplest-example/)

Do "đánh hơi" sai về tham số truyền vào Function, SQL Server sẽ sử dụng một Plan cực kỳ thiếu chính xác để Execute query, dẫn đến tốn quá nhiều chi phí về TIME, IO.

Có trick như sau, để "báo" với SQL Server bỏ qua tính năng "đánh hơi" này:

```sql
CREATE FUNCTION GetCompanyByTaxCodeWithLog(@taxcode VARCHAR(14), @userId INT)
    RETURNS @result TABLE
                    (
                        Name    NVARCHAR(200),
                        Taxcode VARCHAR(14),
                        LogID   INT
                    )
    WITH SCHEMABINDING
AS
BEGIN
    DECLARE @l_taxcode VARCHAR(14), @l_userId INT;
    SET @l_taxcode = @taxcode;
    SET @l_userId = @userId;

    --bla bla
    SELECT @Name = Name, @Code = Taxcode
    FROM Company c
    WHERE c.taxcode = @l_taxcode;
    ---
    RETURN
END
```

Ta tạo và set biến local trong thân Function tương ứng với tham số truyền vào. Sau đó chỉ sử dụng biến local này trong các query tiếp theo.

* Cách này sẽ bỏ qua lợi thế trong trường hợp SQL Server "đánh hơi" đúng. Tuy nhiên trong nhiều trường hợp, bỏ qua tính năng này với Scalar Function/MSTVF là an toàn hơn.

### 3.5. Sử dụng SCHEMABINDING và RETURNS NULL ON NULL INPUT

```WITH SCHEMABINDING``` (như trong các ví dụ trên) giúp SQLServer luôn đảm bảo cấu trúc-schema của Function là nhất quán trong suốt quá trình sủ dụng, truy vấn.

Nếu không có SCHEMABINDING, SQLServer sẽ phải làm thêm 1 bước phụ nữa, đó là copy schema của logic Function, lưu vào TempDB trong khi tạo ExecutionPlan.

* Do đó ```WITH SCHEMABINDING``` trong mọi trường hợp đều mang lại lợi ích về hiệu năng.

```WITH RETURNS NULL ON NULL INPUT``` là 1 Option cho phép bỏ qua tính toán logic trong thân Function, do đó, cải thiện hiệu năng khi phù hợp với business của Function.

2 option này có thể sử dụng đồng thời như sau:

```sql
CREATE FUNCTION GetCompanyByTaxCode(@taxcode VARCHAR(14))
    RETURNS TABLE
        WITH SCHEMABINDING, RETURNS NULL ON NULL INPUT
    AS RETURN
        ----bla bla
```

## 4. Tham khảo

[https://www.sqlshack.com/improvements-of-scalar-user-defined-function-performance-in-sql-server-2019/](https://www.sqlshack.com/improvements-of-scalar-user-defined-function-performance-in-sql-server-2019/)

[https://www.mssqltips.com/sqlservertip/1692/using-schema-binding-to-improve-sql-server-udf-performance/](https://www.mssqltips.com/sqlservertip/1692/using-schema-binding-to-improve-sql-server-udf-performance/)

[https://sqlperformance.com/2018/12/sql-performance/improve-udfs-null-on-null-input](https://sqlperformance.com/2018/12/sql-performance/improve-udfs-null-on-null-input)

[Comment về trick loại bỏ Parameter sniffing trên SO](https://stackoverflow.com/a/1095858/917499)

[Bài viết tương tự về trick xử lý Parameter sniffing cho Function](https://sqlkover.com/optimize-for-unknown-for-inline-table-valued-functions/)