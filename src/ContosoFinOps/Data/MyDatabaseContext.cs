using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.EntityFrameworkCore;
using DotNetCoreSqlDb.Models;

namespace DotNetCoreSqlDb.Data
{
    public class MyDatabaseContext : DbContext
    {
        public MyDatabaseContext (DbContextOptions<MyDatabaseContext> options)
            : base(options)
        {
        }

        public DbSet<DotNetCoreSqlDb.Models.Todo> Todo { get; set; } = default!;

        protected override void OnModelCreating(ModelBuilder modelBuilder)
        {
            var todo = modelBuilder.Entity<Todo>();
            todo.ToTable("Todo");
            todo.Property(x => x.Description).HasColumnType("nvarchar(max)");
            todo.Property(x => x.Category).HasMaxLength(32).HasDefaultValue("IT");
            todo.Property(x => x.Status).HasMaxLength(32).HasDefaultValue("Open");
            todo.Property(x => x.CreatedUtc).HasDefaultValueSql("SYSDATETIMEOFFSET()");
            todo.Property(x => x.UpdatedUtc).HasDefaultValueSql("SYSDATETIMEOFFSET()");
            todo.HasIndex(x => x.Status);
        }
    }
}
