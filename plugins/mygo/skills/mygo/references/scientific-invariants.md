# Scientific-code invariants

- Treat `data/raw/` and project-defined original inputs as immutable.
- Write derived data only to `data/processed/` or the documented equivalent.
- Never silently drop rows, impute values, coerce units, change CRS, merge taxa,
  alter factor levels, or redefine missingness.
- Log row counts before and after joins, filters, deduplication, aggregation, and
  spatial overlays.
- Record join keys, unmatched counts, units, CRS, geometry validity, extent, and
  missing-value rules.
- Use explicit random seeds and record important R, Python, GDAL, PROJ, and system
  package versions.
- Generate figures through reproducible scripts and preserve source data mappings.
- Avoid loading large ecological datasets fully into memory without need; report
  memory and performance risks.
- Use project conventions for R and validate with the narrowest relevant `Rscript`
  command or test framework.
- Quote paths in Bash and use strict mode when compatible with the project.
- Keep intermediate artifacts and worker state out of version control unless the
  project explicitly requires an audit trail.
- Leave scientific interpretation, model choice, exclusion rules, transformations,
  and final acceptance to the primary agent.
