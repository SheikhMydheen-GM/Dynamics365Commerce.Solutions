﻿CREATE
or ALTER VIEW [dbo].[view_FactPaymentTransactions] AS
SELECT *
FROM OPENROWSET (
		BULK N'https://placeholder_storageaccount.dfs.core.windows.net/placeholder_container/placeholder_datarootpath/Ontologies/Commerce/FactPaymentTransactions/*.parquet',
		FORMAT = 'parquet'
	) WITH (
		[PaymentTransactionId] 			bigint,
		[Company] 				nvarchar(4),
		[Amount] 				numeric(32, 6),
		[AmountMaster] 				numeric(32, 6),
		[AmountTendered] 			numeric(32, 6),
		[AuthenticationCode] 			nvarchar(20),
		[BusinessDate] 				date,
		[CardOrAccount] 			nvarchar(30),
		[CardId] 				nvarchar(10),
		[ChangeLine] 				bigint,
		[ChannelId] 				bigint,
		[Counter] 				bigint,
		[CreditMemoNumber] 			nvarchar(30),
		[Currency] 				nvarchar(3),
		[ExchangeRate] 				numeric(32, 6),
		[ExchangeRateMaster] 			numeric(32, 6),
		[GiftCardNumber] 			nvarchar(30),
		[PaymentCaptureFailed] 			bigint,
		[IsPaymentCaptured] 			bigint,
		[IsPrepayment] 				bigint,
		[LineNumber] 				numeric(32, 6),
		[CardNumber] 				nvarchar(30),
		[IsManagersKeyLive] 			bigint,
		[MessageNumber] 			bigint,
		[LocationNumber] 			nvarchar(50),
		[Quantity] 				numeric(32, 6),
		[ReceiptNumber] 			nvarchar(18),
		[IsReplicated] 				bigint,
		[ReplicationCounterFromOrigin] 		bigint,
		[Shift] 				nvarchar(10),
		[ShiftDate] 				date,
		[Operator] 				nvarchar(25),
		[StatementCode] 			nvarchar(25),
		[StaementNumber] 			nvarchar(20),
		[StoreNumber] 				nvarchar(10),
		[PaymentMethod] 			nvarchar(10),
		[RegisterNumber] 			nvarchar(10),
		[TransactioNumber] 			nvarchar(44),
		[EntryStatus] 				nvarchar(50),
		[TransactionDate] 			date,
		[TimeId] 				bigint,
		[VoidStatus] 				nvarchar(50),
		[DefaultDimension] 			bigint,
		[DateId] 				bigint,
		[CompanyId] 				bigint,
		[CurrencyId] 				bigint, 
		[LoyaltyCardId] 			bigint,
		[RetailTerminalId] 			bigint,
		[CustomerId] 				bigint,
		[RetailTenderTypeId] 			bigint,
		[RetailTenderTypeCardId] 		bigint,
		[WorkerId] 				bigint,
		[SysProcessingDateTime] 		datetime2,
		[SysIsDeleted] 				int
	) AS [FactPaymentTransactions]