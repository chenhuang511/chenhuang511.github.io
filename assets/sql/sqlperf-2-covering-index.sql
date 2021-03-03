--setup
set statistics io on;
set statistics time on;

--select * gay ra keyLookup
SELECT *
FROM Sales.SalesOrderDetail AS sod
WHERE sod.ProductID = 776 
option (recompile);

--select rieng productID
SELECT sod.ProductID
FROM Sales.SalesOrderDetail AS sod
WHERE sod.ProductID = 776
option (recompile);

--khong select * van gay ra keyLookup
SELECT sod.ProductID, sod.CarrierTrackingNumber
FROM Sales.SalesOrderDetail AS sod
WHERE sod.ProductID = 776
option (recompile);

--sua nonclusteredIndex 
CREATE INDEX idx_SalesOrderDetail_ProductID_CarrierTrackingNumber ON Sales.SalesOrderDetail (ProductID, CarrierTrackingNumber);

--tao Covering Index
CREATE INDEX idx_SalesOrderDetail_ProductID_CarrierTrackingNumber 
ON Sales.SalesOrderDetail (ProductID) 
INCLUDE (CarrierTrackingNumber)
--WITH DROP_EXISTING;

DROP INDEX idx_SalesOrderDetail_ProductID_CarrierTrackingNumber 
ON Sales.SalesOrderDetail;