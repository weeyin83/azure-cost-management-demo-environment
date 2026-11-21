using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace DotNetCoreSqlDb.Migrations
{
    /// <inheritdoc />
    public partial class AddServiceOrderFields : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "Category",
                table: "Todo",
                type: "nvarchar(32)",
                maxLength: 32,
                nullable: false,
                defaultValue: "IT");

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "CreatedUtc",
                table: "Todo",
                type: "datetimeoffset",
                nullable: false,
                defaultValueSql: "SYSDATETIMEOFFSET()");

            migrationBuilder.AddColumn<string>(
                name: "Status",
                table: "Todo",
                type: "nvarchar(32)",
                maxLength: 32,
                nullable: false,
                defaultValue: "Open");

            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "UpdatedUtc",
                table: "Todo",
                type: "datetimeoffset",
                nullable: false,
                defaultValueSql: "SYSDATETIMEOFFSET()");

            migrationBuilder.CreateIndex(
                name: "IX_Todo_Status",
                table: "Todo",
                column: "Status");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_Todo_Status",
                table: "Todo");

            migrationBuilder.DropColumn(
                name: "Category",
                table: "Todo");

            migrationBuilder.DropColumn(
                name: "CreatedUtc",
                table: "Todo");

            migrationBuilder.DropColumn(
                name: "Status",
                table: "Todo");

            migrationBuilder.DropColumn(
                name: "UpdatedUtc",
                table: "Todo");

        }
    }
}
