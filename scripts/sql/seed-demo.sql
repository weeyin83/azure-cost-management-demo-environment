SET XACT_ABORT ON;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
BEGIN TRANSACTION;
DECLARE @i int = 1;
WHILE @i <= 30
BEGIN
    DECLARE @description nvarchar(500) =
        N'[Contoso seed ' + RIGHT('00' + CONVERT(varchar(2), @i), 2) + N'] ' +
        CASE @i % 3 WHEN 0 THEN N'Quarterly service review'
             WHEN 1 THEN N'Install meeting room equipment' ELSE N'Inspect office facilities' END;
    IF NOT EXISTS (SELECT 1 FROM dbo.Todo WITH (UPDLOCK, HOLDLOCK) WHERE Description = @description)
        INSERT INTO dbo.Todo (Description, Category, Status, CreatedUtc, UpdatedUtc)
        VALUES (@description,
            CASE @i % 3 WHEN 0 THEN 'Consulting' WHEN 1 THEN 'IT' ELSE 'Facilities' END,
            CASE @i % 3 WHEN 0 THEN 'Completed' WHEN 1 THEN 'Open' ELSE 'InProgress' END,
            DATEADD(hour, -@i, SYSDATETIMEOFFSET()), SYSDATETIMEOFFSET());
    SET @i += 1;
END;
COMMIT TRANSACTION;
