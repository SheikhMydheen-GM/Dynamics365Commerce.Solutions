﻿CREATE
or ALTER VIEW [dbo].[view_FactSales] AS
SELECT *
FROM OPENROWSET (
		BULK N'https://placeholder_storageaccount.dfs.core.windows.net/placeholder_container/placeholder_datarootpath/Ontologies/Commerce/FactSales/*.parquet',
		FORMAT = 'parquet'
	) WITH (
		[IsRetailSale] 				int,
		[Company] 				nvarchar(4),
		[ChannelId] 				bigint,
		[StoreNumber] 				nvarchar(10),
		[RegisterNumber] 			nvarchar(10),
		[TransactionNumber] 			nvarchar(44),
		[CategoryId] 				bigint,
		[NetAmountIncludingTax] 		numeric(32, 6),
		[SalesTaxAmount] 			numeric(32, 6),
		[NetAmount] 				numeric(32, 6),
		[CostAmount] 				numeric(32, 6),
		[MarginAmount] 				numeric(32, 6),
		[PeriodicDiscountAmount] 		numeric(32, 6),
		[ManualDiscountAmount] 			numeric(32, 6),
		[TenderDiscountAmount] 			numeric(32, 6),
		[OtherDiscountAmount] 			numeric(32, 6),
		[TotalDiscountAmount] 			numeric(32, 6),
		[Price] 				numeric(32, 6),
		[IsPriceOverriden] 			bigint,
		[Currency] 				nvarchar(3),
		[CustomerAccount] 			nvarchar(38),
		[DefaultDimensionId] 			bigint,
		[ModeOfDelivery] 			nvarchar(10),
		[BatchNumber] 				nvarchar(20),
		[DimensionNumber] 			nvarchar(20),
		[Warehouse] 				nvarchar(10),
		[SerialNumber] 				nvarchar(20),
		[Site] 					nvarchar(10),
		[LotId] 				nvarchar(20),
		[ItemNumber] 				nvarchar(20),
		[LineWasDiscounted] 			int,
		[Quantity] 				numeric(32, 6),
		[ReturnQuantity] 			numeric(32, 6),
		[TransactionDate] 			date,
		[TimeId] 				bigint,
		[Unit] 					nvarchar(10),
		[UnitPrice] 				numeric(32, 6),
		[UnitQuantity] 				numeric(32, 6),
		[VariantNumber] 			nvarchar(10),
		[ModifiedDateAndTime] 			datetime2,
		[CreatedDateAndTime] 			datetime2,
		[CreatedBy] 				nvarchar(20),
		[SalesGroup] 				nvarchar(10),
		[CustomerId] 				bigint,
		[InvoiceCustomerId] 			bigint,
		[ItemId] 				bigint,
		[ProductId] 				bigint,
		[ProductVariantId] 			bigint,
		[WorkerId] 				bigint,
		[DateId] 				int,
		[InvoiceAccount] 			nvarchar(20),
		[InvoiceNumber] 			nvarchar(20),
		[OrderNumber] 				nvarchar(20),
		[InventoryQuantity] 			numeric(32, 6),
		[SalesId] 				bigint,
		[CompanyId] 				bigint,
		[CurrencyId] 				bigint,
		[CommissionAmount] 			numeric(32, 6),
		[DeliveryType] 				nvarchar(100),
		[IsStocked] 				bigint,
		[DueDate] 				date,
		[DeliveryZipPostalCode] 		nvarchar(100),
		[DeliveryCity] 				nvarchar(100),
		[DeliveryCountryRegion] 		nvarchar(100),
		[ChannelReference] 			nvarchar(100),
		[IsReturn] 				int,
		[InventoryDimensionId] 			bigint,
		[RetailLoyaltyCardId] 			bigint,
		[RetailTerminalId] 			bigint,
		[CommissionSalesGroupId] 		bigint,
		[InventoryUnit] 			nvarchar(10),
		[ReturnNetAmount] 			numeric(32, 6),
		[IsOnlineSale] 				int,
		[SalesTaxIncludedInAmount] 		numeric(32, 6),
		[SalesType] 				nvarchar(50),
		[RecordType] 				nvarchar(50),
		[SysProcessingDateTime] 		datetime2,
		[SysIsDeleted] 				int
	) AS [FactSales]