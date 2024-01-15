---
layout: post
title:  "Tối ưu hàng ngày, về một tip đơn giản nhưng RẤT hiệu quả"
description: "Một trong những cách rất đơn giản nhưng mang lại hiệu quả lớn khi tối ưu JOIN query"
tags: sql daily dba join
---

## Tip

> Tip tôi đề cập ở đây đơn giản là: Thu nhỏ tối đa 2 tập hợp trước khi JOIN chúng với nhau.

Muốn thu nhỏ dữ liệu của 2 bảng trước khi JOIN, đơn giản là chúng ta thêm vào các điều kiện WHERE trên cả 2 bảng. 

Chú ý đến việc thêm điều kiện và thứ tự của từng điều kiện trong mệnh đề WHERE để có thể sử dụng index của mỗi bảng một cách tối ưu nhất.

## Bài toán thực tế

Xem xét câu truy vấn dưới đây, và sự khác nhau khi có thêm điều kiện

![image](/assets/images/sqlperf-12-1.png)

* Bảng ```VATInvoice``` đang có khoảng 6M bản ghi, bảng ```TicketHistory``` là khoảng 1.3M bản ghi;
* ```ArisingDate``` có giá trị như nhau trên cả 2 bảng;
* Thời gian truy vấn cho trường hợp bên trái là ``~8s``, bên phải là ``~11s``;

Điểm khác biệt đến từ số ``Logical reads`` giữa 2 trường hợp, query có thêm điều kiện (bên trái) có số lần đọc chỉ bằng 1/5 so với không có điều kiện (bên phải).

### Vậy cách xử lý của SQL Server cụ thể như thế nào?

Chúng ta phân tích query plan của 2 trường hợp trên: plan trên là với trường hợp không có thêm điều kiện ``inv.ArisingDate``, plan bên dưới là có thêm điều kiện.

![image](/assets/images/sqlperf-12-2.png)

* SQLServer lọc trên 2 bảng ``VATInvoice`` ``TicketHistory`` trước khi JOIN chúng;
* Khi có thêm điều kiện với ``ArisingDate``, engine đoán đúng đến ``71%``, số bản ghi thực tế lấy ra cũng chỉ bằng 1/3 so với trường hợp còn lại (``343762`` so với ``1362620``, chỗ khoanh đỏ);
* Ở trường hợp trên, rõ ràng Index sử dụng đang không mang lại hiệu quả, do đó Engine khuyến nghị thay thế bằng 1 Index khác (thực tế là không cần)

Với query trên, khoảng thời gian cần truy vấn là trong tháng (30 ngày), vì thế chưa có sự khác biệt quá rõ rệt về thời gian xử lý.

Tuy nhiên, khi thử nghiệm với khoảng thời gian rộng hơn là 6 tháng, khi có thêm điều kiện chỉ mất khoảng ``12s`` truy vấn, trường hợp còn lại là hơn ``40s``, khác biệt rõ rệt.

Tức là khi phải xử lý trên tập dữ liệu càng lớn, tip này càng thể hiện rõ rệt hiệu năng.

### Lưu ý

Khi đưa thêm điều kiện vào query, luôn nhớ sắp xếp thứ tự:

* Các điều kiện của cùng 1 bảng nên liên tiếp nhau;
* Thứ tự các điều kiện của cùng 1 bảng phải được xem xét dựa trên Index có sẵn.

Trong ví dụ trên, khi thêm ``ArisingDate``, sẽ ngay sau ``ComID`` vì để tận dụng 1 index có sẵn là tổ hợp (ComId, ArisingDate, Pattern).
