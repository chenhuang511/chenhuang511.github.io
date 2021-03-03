--Bat thong tin tra ve cua query
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

USE AdventureWorks2017;
GO

select count(*) from dbo.bigProduct;
select count(*) from dbo.bigTransactionHistory;

--select co di kem cac ham tong hop COUNT/SUM/AVG
SELECT bp.Name AS ProductName,
 COUNT(bth.ProductID),
 SUM(bth.Quantity),
 AVG(bth.ActualCost)
FROM dbo.bigProduct AS bp
 JOIN dbo.bigTransactionHistory AS bth
 ON bth.ProductID = bp.ProductID
GROUP BY bp.Name
OPTION (RECOMPILE);

--tao columnstore index de tuning cau query tren
CREATE NONCLUSTERED COLUMNSTORE INDEX ix_csTest
ON dbo.bigTransactionHistory
(
 ProductID,
 Quantity,
 ActualCost
);

--drop index de test
DROP INDEX ix_csTest ON dbo.bigTransactionHistory;

--neu them dieu kien tu 1 cot nam ngoai columnstore index
select count(ProductID) from dbo.bigTransactionHistory where TransactionDate < '2006-01-01';

--tuong tu them dieu kien voi query tren
SELECT bp.Name AS ProductName,
 COUNT(bth.ProductID),
 SUM(bth.Quantity),
 AVG(bth.ActualCost)
FROM dbo.bigProduct AS bp
 JOIN dbo.bigTransactionHistory AS bth
 ON bth.ProductID = bp.ProductID
WHERE bth.Quantity < 75
AND bth.TransactionDate < '2006-01-01'
GROUP BY bp.Name
OPTION (RECOMPILE);

--tao columnstore index bao tat ca cac cot can query trong ca select/condition
CREATE NONCLUSTERED COLUMNSTORE INDEX ix_csTest_2
ON dbo.bigTransactionHistory(
 ProductID,
 Quantity,
 ActualCost,
 TransactionDate
);

--su dung filtered index cho columnstore index
DROP INDEX ix_csTest_2 ON dbo.bigTransactionHistory;

CREATE NONCLUSTERED COLUMNSTORE INDEX ix_csTest_2
ON dbo.bigTransactionHistory(
 ProductID,
 Quantity,
 ActualCost,
 TransactionDate
) WHERE TransactionDate < '2006-01-01';