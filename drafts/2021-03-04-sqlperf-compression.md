
## 2. Cấu hình nén dữ liệu cho Index

Việc nén dữ liệu (Compression) sẽ tốn thêm chi phí CPU khi thực hiện nén/giải nén; tuy nhiên so với lợi ích đạt được về không gian lưu trữ (cả Disk và RAM) thì chi phí này không đáng kể.

* Ngoài tiết kiệm RAM/Disk, nén index còn giúp tăng tốc query sử dụng index đó; vì số lượng page đọc từ buffer để trả về sẽ giảm đi

* Tức là việc nén dữ liệu Index phần lớn là có lợi cho SQLServer.

[https://docs.microsoft.com/en-us/previous-versions/sql/sql-server-2008/dd894051(v=sql.100)?redirectedfrom=MSDN](https://docs.microsoft.com/en-us/previous-versions/sql/sql-server-2008/dd894051(v=sql.100)?redirectedfrom=MSDN)

<https://thomaslarock.com/2018/01/when-to-use-row-or-page-compression-in-sql-server/#:~:text=S%3A%20The%20percentage%20of%20scan,it%20is%20for%20page%20compression.>