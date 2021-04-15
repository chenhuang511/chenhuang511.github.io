---
layout: post
title:  "Đánh giá và xử lý Deadlock"
description: "Cơ bản về lock/block và cách theo dõi, loại bỏ deadlock"
tags: sql index deadlock dba
---

##  <a name="head1"> 1. Nguyên nhân gây ra Deadlock

Deadlock là một ngữ cảnh trong đó 2 process block lẫn nhau. Mỗi Process trong ngữ cảnh này khi đó đang nắm giữ (lock) resource của riêng mình, và cố gắng truy cập vào resource bị lock của đối phương. Khi đó 1 trong 2 process sẽ bị chọn làm nạn nhân của deadlock.

Chúng ta hay gặp deadlock bắn ra từ Exception của App chẳng hạn, khi thực hiện một truy vấn đến DB.

Ta xem xét trường hợp Deadlock như hình dưới đây (cách để lấy thông tin deadlock ta sẽ bàn sau):

![image](/assets/images/sqlperf-4-deadlock-1.png)

Trước tiên ta lướt qua một số khái niệm trên hình:
* Có 2 process là 2 hình elip bên trái và phải của hình vẽ, với ProcessID tương ứng lần lượt là ```139``` và ```101```.
* Process 139 là nạn nhân của ngữ cảnh deadlock này, và có dấu gạch chéo màu xanh.
* 2 khóa (lock) là 2 hình chữ nhật ở giữa hình, và có 2 kiểu là Key-Lock và Object-Lock.
* Request: là yêu cầu lấy khóa từ process.
* Owner: là chỉ process đang sở hữu khóa.
* Mode S: là chế độ lấy khóa ```Share```, khóa này được dùng để ĐỌC dữ liệu.
* Mode X: là chế độ lấy khóa ```Exclusive```, khóa độc quyền để GHI dữ liệu.
* Mode IX: là chế độ lấy khóa ```Intent Exclusive```, khóa độc quyền để GHI dữ liệu. Mode IX tương tự Mode X nhưng ở mức thấp hơn, tức là: Có dự định lấy khóa Mode X.
* Ngoài ra còn có ```Mode U```: là LockMode khi update dữ liệu. Ban đầu, process sẽ ĐỌC dữ liệu ra (dùng khóa S), sau đó sẽ CẬP NHẬT dữ liệu (dùng khóa X). Do đó có thể hiểu nôm na: ```U = S + X```.

Diễn giải ngữ cảnh Deadlock trên như sau:

* Process 139 đang nắm giữ Object-Lock (Owner Mode: S), và đang yêu cầu lấy Key-Lock (Request Mode: S).
* Process 101 đang nắm giữ Key-Lock (Owner Mode: X), và đang yêu cầu lấy Object-Lock (Request Mode: IX)
* 2 process trên đều đang giữ khóa của mình và yêu cầu lấy khóa của đối phương. Điều này gây ra một vòng luẩn quẩn, chúng block lẫn nhau, và gây ra deadlock.
* SQLServer chọn process 139 là nạn nhân, nguyên nhân chính là SQLServer xác định Process 139 sẽ tác động lên ít tài nguyên hơn Process 101, do đó việc roll-back process 139 sẽ tốn ít chi phí hơn khi roll-back 101.

## <a name="head2"> 2. Cách xác định và hiển thị deadlockGraph 

Ta sử dụng truy vấn sau để lấy tất cả deadLock đã lưu lại trong SQLServer:

```sql
DECLARE @path NVARCHAR(260)
--to retrieve the local path of system_health files
SELECT @path = dosdlc.path
FROM sys.dm_os_server_diagnostics_log_configurations AS dosdlc;
SELECT @path = @path + N'system_health_*';
WITH fxd
         AS (SELECT CAST(fx.event_data AS XML) AS Event_Data
             FROM sys.fn_xe_file_target_read_file(@path,
                                                  NULL,
                                                  NULL,
                                                  NULL) AS fx)
SELECT dl.deadlockgraph
FROM (SELECT dl.query('.') AS deadlockgraph
      FROM fxd
               CROSS APPLY event_data.nodes('(/event/data/value/deadlock)') AS d(dl)) AS dl;
```

![image](/assets/images/sqlperf-4-deadlock-2.png)

Kết quả sẽ ra được thông tin Graph như hình trên, dưới định dạng SQLServer lưu trữ là XML.

Ta cần chuyển dữ liệu XML này thành Graph thể hiện như ở [Mục 1](#head1) như sau:
* click vào 1 row kết quả XML của query, hiển thị full XML trên SSMS.
* Copy full XMl và paste vào notepad, save lại dưới định dạng file ```.xdl```
* Mở file ```.xdl``` vừa tạo trong SSMS: File -> Open...

![image](/assets/images/sqlperf-4-deadlock-3.png)


## 3. Cách xem xét các query trong ngữ cảnh Deadlock

Ta cần biết các query đang tham gia vào ngữ cảnh Deadlock, để hiểu chúng đang tranh chấp những khóa nào. Từ đó để có thể chỉnh sửa query/index/table...để tránh deadlock xảy ra.

Đơn giản ta chỉ cần chỉ con trỏ chuột vào Process trong Graph (.xdl) như ở [Mục 2](#head2), ta sẽ thấy thông tin Query của Process:

![image](/assets/images/sqlperf-4-deadlock-4.png)