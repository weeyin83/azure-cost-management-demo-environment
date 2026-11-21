SET XACT_ABORT ON;
DECLARE @name sysname = N'$(RuntimeUser)';
DECLARE @sid varbinary(16) = 0x$(RuntimeSid);
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @name AND (sid <> @sid OR type <> 'E'))
    THROW 50001, 'Existing runtime user does not match the selected Entra identity.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @name)
    CREATE USER [$(RuntimeUser)] FROM EXTERNAL PROVIDER;
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @name AND (sid <> @sid OR type <> 'E'))
    THROW 50004, 'Resolved SQL identity does not match the verified managed identity client ID.', 1;
IF EXISTS (SELECT 1 FROM sys.database_role_members WHERE member_principal_id = USER_ID(@name))
    THROW 50002, 'Runtime identity already has database roles. Review and remove excess privileges explicitly.', 1;
IF EXISTS (SELECT 1 FROM sys.database_permissions
    WHERE grantee_principal_id = USER_ID(@name)
      AND (state <> 'G' OR NOT (
          (class = 1 AND major_id = OBJECT_ID(N'dbo.Todo')
              AND permission_name IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE'))
          OR (class = 0 AND permission_name = 'CONNECT'))))
    THROW 50003, 'Runtime identity has unexpected permissions. Review them before continuing.', 1;
GRANT SELECT, INSERT, UPDATE, DELETE ON OBJECT::dbo.Todo TO [$(RuntimeUser)];
