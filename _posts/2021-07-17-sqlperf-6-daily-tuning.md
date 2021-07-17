---
layout: post
title:  "Nhật ký tuning 01"
description: "Tuning dạo thường ngày, giết thời gian =))"
tags: sql tuning daily
---

## 1. Tìm kiếm các query chậm trong QueryStore

Với điều kiện DB đã ON phần ```query Store```, nếu chưa, bật và theo dõi vào tuần tiếp theo:

```sql
ALTER DATABASE [your_db] SET QUERY_STORE = ON;
```

Tìm kiếm query chậm, sắp xếp theo thời gian exec trung bình giảm dần:

```sql
select qsqt.query_sql_text,
       qsrs.count_executions,
       qsrs.avg_duration / 1000000 as avg_duration_sec,
       qsrs.max_duration / 1000000 as max_duration_sec,
       qsrs.max_rowcount,
       qsrs.avg_logical_io_reads,
       qsrs.avg_physical_io_reads,
--        qsws.total_query_wait_time_ms / 1000 as total_query_wait_time_sec,
--        qsws.avg_query_wait_time_ms / 1000 asavg_query_wait_time_sec ,
       qsws.total_query_wait_time_ms,
       qsws.avg_query_wait_time_ms,
       qsrsi.start_time,
       qsrsi.end_time
FROM sys.query_store_plan qsp
         JOIN sys.query_store_query AS qsq ON qsp.query_id = qsq.query_id
         JOIN sys.query_store_query_text qsqt ON qsq.query_text_id = qsqt.query_text_id
         JOIN sys.query_store_runtime_stats qsrs ON qsp.plan_id = qsrs.plan_id
         JOIn sys.query_store_runtime_stats_interval qsrsi
              ON qsrs.runtime_stats_interval_id = qsrsi.runtime_stats_interval_id
         JOIN sys.query_store_wait_stats qsws
              ON qsrsi.runtime_stats_interval_id = qsws.runtime_stats_interval_id
                  AND qsws.plan_id = qsrs.plan_id
                  AND qsws.execution_type = qsrs.execution_type
WHERE qsrsi.start_time > '2021-07-01'
ORDER BY avg_duration_sec DESC
```

Ở đây tôi đang tìm kiếm tính từ ngày 01/07/2021. Kết quả như sau:

![image](/assets/images/sqlperf-6-1.png)

Mục tiêu là query đang được khoanh đỏ, tuy avg_duration là **~30s** nhưng số lần chạy (count_execution) = **38**

Lấy ```query_text``` chuyển sang **DataGrip** format cho đẹp, ta có query cần xử lý như sau:

```sql
declare @P0 varbinary(8000),@P1 nvarchar(4000),@P2 nvarchar(4000),@P3 nvarchar(4000),@P4 nvarchar(4000)
SELECT COUNT(*)
from SABill sa
where CompanyID = @P0
  and sa.ID not in (select SABillID
                    from PPDiscountReturnDetail
                    where SABillID is not null
                    union
                    select SABillID
                    from SAInvoiceDetail
                    where SABillID is not null
                    union
                    select SAInvoiceID
                    from IADeletedInvoice
                    where SAInvoiceID is not null
                    union
                    select SABillID
                    from SAReturnDetail
                    where SABillID is not null)
  and sa.CurrencyID = @P1
  AND @P2 <= CONVERT(varchar, sa.InvoiceDate, 112)
  AND @P3 >= CONVERT(varchar, sa.InvoiceDate, 112)
  and (sa.typeLedger = @P4 or sa.typeLedger = 2)
```

Nhìn qua thấy ngay vấn đề rồi =))

## 2. Tuning dạo

### 2.1. Đánh giá

Bật ```statistic io``` và ```statistic time``` trước khi exec query:

```sql
set statistics time,io on;
```

Lựa chọn ngẫu nhiên các tham số @P0->@P4. Các tham số này ăn theo nghiệp vụ của phần mềm của chúng tôi.

```sql
set @P0 = '6F895978-55DE-A641-837D-EB4532C0A3A5'
set @P1 = 'VND'
set @P2 = '2021-01-01'
set @P3 = '2021-07-17'
set @P4 = 0
```

Thử execute với tham số trên, thêm ```option (recompile)``` để bỏ qua planCaching, yêu cầu SQLServer compile lại queryPlan mới.

![image](/assets/images/sqlperf-6-2.png)

Chạy hết **39s** kết quả trả về là **3117**. Từ statistic trả về ta thấy có 2 vấn đề nổi bật như sau:

* Thời gian trả về 39s đúng như report từ QueryStore, quá lâu cho 1 query đơn giản.
* SQLServer đã scan 3,3M pages ở bảng SAInvoiceDetail.

Ngó qua Plan (ảnh chụp các phần quan trọng của plan, không phải toàn bộ)

![image](/assets/images/sqlperf-6-3.png)

![image](/assets/images/sqlperf-6-4.png)

* Một thông báo warning về ngầm chuyển kiểu dữ liệu (implicit conversion) ở đoạn ```CONVERT(varchar, sa.InvoiceDate, 112)```. Chuyển kiểu đang bị ngược với mức độ ưu tiên của các Type nên SQLServer sẽ thông báo.
* Một indexScan đang tốn rất nhiều chi phí trên bảng ```SAInvoiceDetail```. Đây chính là nguyên nhân khiến SQLServer phải read 3,3M pages ở bảng này.

### 2.2. Xử lý

#### 2.2.1. Loại bỏ function

Vấn đề lớn nhất nằm ở đoạn 
```sql
  AND @P2 <= CONVERT(varchar, sa.InvoiceDate, 112)
  AND @P3 >= CONVERT(varchar, sa.InvoiceDate, 112)
```

Đây rõ ràng là tìm kiếm từ ngày-đến ngày, và đầu vào của chúng ta đang là đúng theo kết quả của hàm ```CONVERT```, do đó việc convert này là thừa.

Và việc sử dụng Function (hàm CONVERT) ở điều kiện WHERE khiến cho tiêu chí WHERE này là ```non-sargable```. Function ở WHERE thường gây ra vấn đề hiệu năng lớn cho SQLServer.

Rõ ràng ta có thể thay thế 2 điều kiện tìm kiếm trên một cách đơn giản như sau:

```sql
AND sa.InvoiceDate BETWEEN @P2 AND @P3
```

#### 2.2.2. Loại bỏ indexScan

Để loại bỏ IndexScan đang tồn tại trên bảng ```SAInvoiceDetail```, đơn giản là thêm một Index ở đây, để plan có thể sử dụng ```IndexSeek``` như với các bảng còn lại.

```sql
CREATE NONCLUSTERED INDEX idx_SAInvoiceDetail_SABill ON SAInvoiceDetail (SABillID)
WHERE SABillID IS NOT NULL
```

Ở đây tôi dùng ```FilteredIndex``` vì logic là đang tìm với điều kiện ```... SABillID IS NOT NULL```

#### 2.2.3. Mượt thêm chút

Một điểm lưu ý là query đang dùng ```UNION```, từ logic query thấy rằng hoàn toàn có thể thay thế bằng ```UNION ALL```. Tức là ta không cần quan tâm đến việc loại bỏ trùng lặp ở đây. Hiệu năng của ```UNION ALL``` luôn luôn tốt hơn so với ```UNION```.

Cuối cùng ta có query như sau:

```sql
SELECT COUNT(*)
from SABill sa
where CompanyID = '6F895978-55DE-A641-837D-EB4532C0A3A5'
  and sa.ID not in (select SABillID
                    from PPDiscountReturnDetail
                    where SABillID is not null
                    union all
                    select SABillID
                    from SAInvoiceDetail
                    where SABillID is not null
                    union all
                    select SAInvoiceID
                    from IADeletedInvoice
                    where SAInvoiceID is not null
                    union all
                    select SABillID
                    from SAReturnDetail
                    where SABillID is not null)
  and sa.CurrencyID = 'VND'
  and sa.InvoiceDate between '2021-01-01' and '2021-07-17'
  and (sa.typeLedger = 0 or sa.typeLedger = 2)
```

Execute query trên, ta thu được kết quả **QUÁ_KINH_NGẠC :))**

![image](/assets/images/sqlperf-6-5.png)

* Thay vì **39s** ta có kết quả mới là **127ms**. Thay vì đọc **3,3M** pages từ ```SAInvoiceDetail```, chỉ còn **9427** pages.
* Ngoài ra SQLServer cũng không còn warning về Implicit Conversion nữa, vì ta có dùng hàm ```CONVERT``` để chuyển type nữa đâu.

Đây có thể coi là thành công lớn về hiệu năng, và có thể kết thúc việc tuning dạo ở query này ở đây.
