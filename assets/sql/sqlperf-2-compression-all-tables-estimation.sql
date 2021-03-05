-- idea from https://www.sqlservercentral.com/scripts/estimate-compression-for-all-tables-and-indexes-with-both-row-and-page
-- but only one row per index, status msg, columnstore too, resume option
set xact_abort, nocount on

-- if you want to start over from scratch; run this
--DROP TABLE if exists dbo.CompressionEstimateResultSet

if not exists (select * from sys.tables t where t.name='CompressionEstimateResultSet') begin
create table dbo.CompressionEstimateResultSet
(
object_name sysname not null
, schema_name sysname not null
, index_id int not null
, partition_number int not null
, PageSize bigint null
, RowSize bigint null
, NoneSize bigint null
, CSSize bigint null
, CSASize bigint null
);
end
declare @CompressionEstimate table
(
object_name sysname not null
, schema_name sysname not null
, index_id int not null
, partition_number int null
, [size_with_current_compression_setting (KB)] bigint null
, [size_with_requested_compression_setting (KB)] bigint null
, [sample_size_with_current_compression_setting (KB)] bigint null
, [sample_size_with_requested_compression_setting (KB)] bigint null
);

declare @schema_nameX sysname, @object_nameX sysname, @index_idX int, @d varchar(19)
declare CompressionEstimateCursor cursor local read_only forward_only for
select distinct
S.name as schemaname, O.name as tablename, I.index_id
from sys.indexes as I
inner join
sys.partitions as P
on P.object_id = I.object_id
and P.index_id = I.index_id
inner join
sys.objects O
on O.object_id = I.object_id
inner join
sys.schemas S
on S.schema_id = O.schema_id
where I.object_id > 100
and S.name not in ( 'sys', 'CDC' )
and p.rows > 0
and not exists (select * from dbo.CompressionEstimateResultSet r where r.object_name=o.name and r.schema_name=s.name) /* pick up from where we stopped last time */
order by s.name, o.name

open CompressionEstimateCursor;
fetch next from CompressionEstimateCursor
into @schema_nameX, @object_nameX, @index_idX;
while (@@fetch_status = 0)
begin
set @d = convert(varchar(19), getdate(), 120)
raiserror ('at %s table %s.%s index: %i ', 10, 1, @d, @schema_nameX, @object_nameX, @index_idX) with nowait

begin try
insert into @CompressionEstimate
exec sys.sp_estimate_data_compression_savings @schema_name = @schema_nameX, @object_name = @object_nameX, @index_id = @index_idX, @partition_number = null, @data_compression = 'None';
end try
begin catch
--select ERROR_NUMBER() as here3
raiserror ('ERROR at None: %s table %s.%s index: %i ', 10, 1, @d, @schema_nameX, @object_nameX, @index_idX) with nowait
if ERROR_NUMBER() <> 1701 begin
;throw
end
end catch

insert into dbo.CompressionEstimateResultSet
(
object_name
, schema_name
, index_id
, partition_number
, NoneSize
)
select object_name, schema_name, index_id, partition_number, [size_with_requested_compression_setting (KB)]
from @CompressionEstimate;

delete from @CompressionEstimate;
begin try
insert into @CompressionEstimate
exec sys.sp_estimate_data_compression_savings @schema_name = @schema_nameX, @object_name = @object_nameX, @index_id = @index_idX, @partition_number = null, @data_compression = 'Row';
end try
begin catch
raiserror ('ERROR at row: %s table %s.%s index: %i ', 10, 1, @d, @schema_nameX, @object_nameX, @index_idX) with nowait
if ERROR_NUMBER() <> 1701 begin
;throw
end
end catch
update t
set RowSize = ce.[size_with_requested_compression_setting (KB)]
from @CompressionEstimate ce
INNER JOIN dbo.CompressionEstimateResultSet t on ce.object_name = t.object_name and t.schema_name=ce.schema_name and t.index_id = ce.index_id and t.partition_number = ce.partition_number
where 1=1

delete from @CompressionEstimate;
begin try
insert into @CompressionEstimate
exec sys.sp_estimate_data_compression_savings @schema_name = @schema_nameX, @object_name = @object_nameX, @index_id = @index_idX, @partition_number = null, @data_compression = 'Page';
end try
begin catch
raiserror ('ERROR at Page: %s table %s.%s index: %i ', 10, 1, @d, @schema_nameX, @object_nameX, @index_idX) with nowait
if ERROR_NUMBER() <> 1701 begin
;throw
end
end catch
update t
set pageSize = ce.[size_with_requested_compression_setting (KB)]
from @CompressionEstimate ce
INNER JOIN dbo.CompressionEstimateResultSet t on ce.object_name = t.object_name and t.schema_name=ce.schema_name and t.index_id = ce.index_id and t.partition_number = ce.partition_number
where 1=1

delete from @CompressionEstimate;
begin try
insert into @CompressionEstimate
exec sys.sp_estimate_data_compression_savings @schema_name = @schema_nameX, @object_name = @object_nameX, @index_id = @index_idX, @partition_number = null, @data_compression = 'ColumnStore';
end try
begin catch
raiserror ('ERROR at ColumnStore: %s table %s.%s index: %i ', 10, 1, @d, @schema_nameX, @object_nameX, @index_idX) with nowait
if ERROR_NUMBER() not in (1701, 35343) begin
/* 
Msg 1701, Level 16, State 1, Line 29
Creating or altering table '#z' failed because the minimum row size would be x, including y bytes of internal overhead. This exceeds the maximum allowable table row size of 8060 bytes.
Msg 35343, Level 16, State 1, Line 1
The statement failed. Column 'DATA_DEFAULT' has a data type that cannot participate in a columnstore index.
*/
;throw
end
end catch
update t
set CSSize = ce.[size_with_requested_compression_setting (KB)]
from @CompressionEstimate ce
INNER JOIN dbo.CompressionEstimateResultSet t on ce.object_name = t.object_name and t.schema_name=ce.schema_name and t.index_id = ce.index_id and t.partition_number = ce.partition_number
where 1=1

delete from @CompressionEstimate;
begin try
insert into @CompressionEstimate
exec sys.sp_estimate_data_compression_savings @schema_name = @schema_nameX, @object_name = @object_nameX, @index_id = @index_idX, @partition_number = null, @data_compression = 'COLUMNSTORE_ARCHIVE';
end try
begin catch
--select ERROR_NUMBER() as here2
raiserror ('ERROR at COLUMNSTORE_ARCHIVE: %s table %s.%s index: %i ', 10, 1, @d, @schema_nameX, @object_nameX, @index_idX) with nowait
if ERROR_NUMBER() not in (1701, 35343) begin
/* 
Msg 1701, Level 16, State 1, Line 29
Creating or altering table '#z' failed because the minimum row size would be x, including y bytes of internal overhead. This exceeds the maximum allowable table row size of 8060 bytes.
Msg 35343, Level 16, State 1, Line 1
The statement failed. Column 'DATA_DEFAULT' has a data type that cannot participate in a columnstore index.
*/
;throw
end
end catch
update t
set CSASize = ce.[size_with_requested_compression_setting (KB)]
from @CompressionEstimate ce
INNER JOIN dbo.CompressionEstimateResultSet t on ce.object_name = t.object_name and t.schema_name=ce.schema_name and t.index_id = ce.index_id and t.partition_number = ce.partition_number
where 1=1

delete from @CompressionEstimate;
fetch next from CompressionEstimateCursor
into @schema_nameX, @object_nameX, @index_idX;
end;
close CompressionEstimateCursor;
deallocate CompressionEstimateCursor;

/* report for SSMS */
SELECT a.TableName, a.HeapOrClustered
, format(a.TableNoneSize, 'N0') as TableNoneKB
, format(a.TableRowSize , 'N0') as TableRowKB
, format(a.TablePageSize, 'N0') as TablePageKB
, a.TableCSSize
, a.TableCSASize
, format(a.IndexNoneSize, 'N0') as IndexNoneKB
, format(a.IndexRowSize , 'N0') as IndexRowKB
, format(a.IndexPageSize, 'N0') as IndexPageKB
, a.IndexCSSize
, a.IndexCSASize
, format((100.0 * TableRowSize / nullif(TableNoneSize,0)), 'N0') as TableRowSpaceSavingsPct
, format((100.0 * TablePageSize / nullif(TableNoneSize,0)), 'N0') as TablePageSpaceSavingsPct
, format((100.0 * TableCSSize / nullif(TableNoneSize,0)), 'N0') as TableCSSpaceSavingsPct
, format((100.0 * TableCSASize / nullif(TableNoneSize,0)), 'N0') as TableCSASpaceSavingsPct
, format((100.0 * IndexRowSize / nullif(IndexNoneSize,0)), 'N0') as IndexRowSpaceSavingsPct
, format((100.0 * IndexPageSize / nullif(IndexNoneSize,0)), 'N0') as IndexPageSpaceSavingsPct
, format((100.0 * IndexCSSize / nullif(IndexNoneSize,0)), 'N0') as IndexCSSpaceSavingsPct
, format((100.0 * IndexCSASize / nullif(IndexNoneSize,0)), 'N0') as IndexCSASpaceSavingsPct
, case when a.NumberOfIndexes = 1 and a.HeapOrClustered='HEAP' then 0 else a.NumberOfIndexes end as NumberOfIndexes
from (
select r.schema_name + '.' + r.object_name as TableName
, min(case when r.index_id = 0 then 'HEAP' else 'Clustered' end) as HeapOrClustered
, sum(case when r.index_id < 2 then r.RowSize end) as TableRowSize
, sum(case when r.index_id < 2 then r.PageSize end) as TablePageSize
, sum(case when r.index_id < 2 then r.NoneSize end) as TableNoneSize
, sum(case when r.index_id < 2 then r.CSSize end) as TableCSSize
, sum(case when r.index_id < 2 then r.CSASize end) as TableCSASize
, sum(case when r.index_id >= 2 then r.RowSize end) as IndexRowSize
, sum(case when r.index_id >= 2 then r.PageSize end) as IndexPageSize
, sum(case when r.index_id >= 2 then r.NoneSize end) as IndexNoneSize
, sum(case when r.index_id >= 2 then r.CSSize end) as IndexCSSize
, sum(case when r.index_id >= 2 then r.CSASize end) as IndexCSASize
, count(distinct r.index_id) as NumberOfIndexes
from dbo.CompressionEstimateResultSet r
group by r.schema_name, r.object_name
) as a
order by a.TableName