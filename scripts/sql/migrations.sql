IF OBJECT_ID(N'[__EFMigrationsHistory]') IS NULL
BEGIN
    CREATE TABLE [__EFMigrationsHistory] (
        [MigrationId] nvarchar(150) NOT NULL,
        [ProductVersion] nvarchar(32) NOT NULL,
        CONSTRAINT [PK___EFMigrationsHistory] PRIMARY KEY ([MigrationId])
    );
END;
GO

BEGIN TRANSACTION;
IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20240621154946_InitialCreate'
)
BEGIN
    CREATE TABLE [Todo] (
        [ID] int NOT NULL IDENTITY,
        [Description] nvarchar(max) NULL,
        [CreatedDate] datetime2 NOT NULL,
        CONSTRAINT [PK_Todo] PRIMARY KEY ([ID])
    );
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20240621154946_InitialCreate'
)
BEGIN
    INSERT INTO [__EFMigrationsHistory] ([MigrationId], [ProductVersion])
    VALUES (N'20240621154946_InitialCreate', N'10.0.10');
END;

COMMIT;
GO

BEGIN TRANSACTION;
IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260820122014_SimplifyTodoSchema'
)
BEGIN
    DECLARE @var nvarchar(max);
    SELECT @var = QUOTENAME([d].[name])
    FROM [sys].[default_constraints] [d]
    INNER JOIN [sys].[columns] [c] ON [d].[parent_column_id] = [c].[column_id] AND [d].[parent_object_id] = [c].[object_id]
    WHERE ([d].[parent_object_id] = OBJECT_ID(N'[Todo]') AND [c].[name] = N'CreatedDate');
    IF @var IS NOT NULL EXEC(N'ALTER TABLE [Todo] DROP CONSTRAINT ' + @var + ';');
    ALTER TABLE [Todo] DROP COLUMN [CreatedDate];
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260820122014_SimplifyTodoSchema'
)
BEGIN
    UPDATE [Todo] SET [Description] = N'' WHERE [Description] IS NULL;
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260820122014_SimplifyTodoSchema'
)
BEGIN
    DECLARE @var1 nvarchar(max);
    SELECT @var1 = QUOTENAME([d].[name])
    FROM [sys].[default_constraints] [d]
    INNER JOIN [sys].[columns] [c] ON [d].[parent_column_id] = [c].[column_id] AND [d].[parent_object_id] = [c].[object_id]
    WHERE ([d].[parent_object_id] = OBJECT_ID(N'[Todo]') AND [c].[name] = N'Description');
    IF @var1 IS NOT NULL EXEC(N'ALTER TABLE [Todo] DROP CONSTRAINT ' + @var1 + ';');
    EXEC(N'UPDATE [Todo] SET [Description] = N'''' WHERE [Description] IS NULL');
    ALTER TABLE [Todo] ALTER COLUMN [Description] nvarchar(max) NOT NULL;
    ALTER TABLE [Todo] ADD DEFAULT N'' FOR [Description];
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260820122014_SimplifyTodoSchema'
)
BEGIN
    INSERT INTO [__EFMigrationsHistory] ([MigrationId], [ProductVersion])
    VALUES (N'20260820122014_SimplifyTodoSchema', N'10.0.10');
END;

COMMIT;
GO

BEGIN TRANSACTION;
IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261121162210_AddServiceOrderFields'
)
BEGIN
    ALTER TABLE [Todo] ADD [Category] nvarchar(32) NOT NULL DEFAULT N'IT';
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261121162210_AddServiceOrderFields'
)
BEGIN
    ALTER TABLE [Todo] ADD [CreatedUtc] datetimeoffset NOT NULL DEFAULT (SYSDATETIMEOFFSET());
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261121162210_AddServiceOrderFields'
)
BEGIN
    ALTER TABLE [Todo] ADD [Status] nvarchar(32) NOT NULL DEFAULT N'Open';
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261121162210_AddServiceOrderFields'
)
BEGIN
    ALTER TABLE [Todo] ADD [UpdatedUtc] datetimeoffset NOT NULL DEFAULT (SYSDATETIMEOFFSET());
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261121162210_AddServiceOrderFields'
)
BEGIN
    CREATE INDEX [IX_Todo_Status] ON [Todo] ([Status]);
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261121162210_AddServiceOrderFields'
)
BEGIN
    INSERT INTO [__EFMigrationsHistory] ([MigrationId], [ProductVersion])
    VALUES (N'20261121162210_AddServiceOrderFields', N'10.0.10');
END;

COMMIT;
GO

