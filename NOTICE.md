# Attribution and reuse

Application foundation: Microsoft / Azure-Samples,
[`msdocs-app-service-sqldb-dotnetcore`](https://github.com/Azure-Samples/msdocs-app-service-sqldb-dotnetcore/tree/7538f5b5260151e1c7ec75060705f923c61cacb9),
commit `7538f5b5260151e1c7ec75060705f923c61cacb9`. The full upstream MIT
notice is retained in `LICENSE.md`. Preserve that notice in redistributions.

Adaptations: four deployment roles, API/HTTP service extraction, fictional service
orders, reporting, validation, telemetry, deployment templates and documentation.
The original namespace, Todo table, Razor forms and EF migration lineage remain.
The complete imported file inventory is in `docs/upstream-files.txt`.
Dev-container conventions are adapted at the user's direction from
[`weeyin83/dev-container-template`](https://github.com/weeyin83/dev-container-template/tree/1f6968dc1f57363fa0bdb6f407a8f88d32ef32f8).
No separate MIT licence is asserted for that reference repository.

Referenced Azure Verified Modules are pinned to serverfarm 0.7.0, site 0.24.0 and
SQL server 0.23.0 from [Azure/bicep-registry-modules](https://github.com/Azure/bicep-registry-modules).
Their Microsoft MIT notices are preserved in `LICENSE-AVM.txt`; retain them if
redistributing restored module source.

Unmodified browser libraries copied with their upstream notices:
- Bootstrap (`wwwroot/lib/bootstrap/LICENSE`), MIT.
- jQuery (`wwwroot/lib/jquery/LICENSE.txt`), MIT.
- jQuery Validation (`wwwroot/lib/jquery-validation/LICENSE.md`), MIT.
- jQuery Validation Unobtrusive (`wwwroot/lib/jquery-validation-unobtrusive/LICENSE.txt`), MIT.

Restored dependency licence metadata, copyright and original notice files are
retained in `THIRD-PARTY-NOTICES.txt`. Most packages declare MIT, but
`Microsoft.Data.SqlClient.SNI.runtime` uses Microsoft Software License Terms,
not MIT. Those terms permit object-code distribution as part of applications
subject to their distribution requirements, including protective end-user terms;
they do not permit standalone unrestricted redistribution. The deployment script
publishes framework-dependent `linux-x64` output, excluding Windows native SNI
libraries. Windows development use and Windows binary redistribution have
different obligations; retain/review the complete SNI terms before the latter.

The app publish output includes this notice, the upstream MIT licence and dependency
notices. Retain the vendor licence files under `wwwroot`. Refresh dependency
notices after changing packages and review exact published binary contents.
MIT permission
does not grant Microsoft/Contoso trademarks or rights to unrelated images/media.
No customer data or paid-media assets are included.
