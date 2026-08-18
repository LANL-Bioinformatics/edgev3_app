# Required Data

This deployment keeps the application images separate from host-managed data. Docker Compose mounts `./data/refdata` into the EDGEv3 containers as `/project/refdata`, and mounts `./data/output/*` as the writable runtime workspace.

The web UI can start with only the runtime directories and generated secrets in place. Full workflow execution also requires the reference databases and workflow container images used by the selected modules.

## Minimum Local Bundle

These files and directories are required for the Docker bundle itself:

| Item | Path |
| --- | --- |
| Compose topology | `docker-compose.yaml` |
| Lifecycle helper | `edgev3_app.sh` |
| Application image archive | `docker_images/edgev3_20260818_amd64.tgz` |
| Nextflow runtime image archive | `docker_images/edgev3-nextflow_20260721_amd64.tgz` |
| MongoDB image archive | `docker_images/edgev3-mongo_20260818_amd64.tgz` |
| Nginx image archive | `docker_images/nginx_latest_amd64.tgz` |
| Server environment template | `data/webapp_server.env.example` |
| Client environment | `data/webapp_client.env` |
| Nginx config and splash page | `data/web_nginx.conf`, `data/splash.html` |
| Nextflow local/container config | `data/local.config`, `data/container.config` |
| Runtime output root | `data/output/` |
| Reference-data root | `data/refdata/` |

`edgev3_app.sh init` and `edgev3_app.sh start` create or reuse the local secrets under `data/secrets/`. Do not check those generated files into Git.

## Runtime Output Directories

The `edgev3_data_init` service makes the bind-mounted output directories writable by the non-root EDGEv3 application process.

| Host path | Container path | Purpose |
| --- | --- | --- |
| `data/output/projects` | `/edgev3/io/projects` | Project working directories, Nextflow outputs, reports, and cached AI summaries. |
| `data/output/db` | `/edgev3/io/db` | Application-created database backups. |
| `data/output/log` | `/edgev3/io/log` | Application and workflow logs. |
| `data/output/public` | `/edgev3/io/public` | Public example/reference files served by the web app. |
| `data/output/sra` | `/edgev3/io/sra` | SRA workflow output. |
| `data/output/upload` | `/edgev3/io/upload` | Uploaded input files and upload temp files. |
| `data/output/bulksubmissions` | `/edgev3/io/bulksubmissions` | Bulk submission files and results. |

## Generated Secrets And Volumes

The helper script generates these files on first start:

- `data/secrets/mongo_root_user.txt`
- `data/secrets/mongo_root_pass.txt`
- `data/secrets/mongo_app_user.txt`
- `data/secrets/mongo_app_pass.txt`
- `data/secrets/mongo_admin_user.txt`
- `data/secrets/mongo_admin_pass.txt`
- `data/secrets/edgev3_admin_password.txt`
- `data/secrets/edgev3_admin_code.txt`
- `data/secrets/webapp_server.env`

Docker also creates these named volumes:

- `mongo_data`, mounted at `/data/db` in MongoDB.
- `nextflowbinaries`, mounted at `/opt/conda` in the EDGEv3 and Nextflow runtime containers.

Keep `data/secrets/` and the `mongo_data` volume together when preserving an initialized deployment. If MongoDB credentials are rotated, the MongoDB volume must be reinitialized.

## Reference Data For Workflows

Only the modules enabled for a submitted workflow need their matching reference data. The paths below are container paths; on the host, replace `/project/refdata` with `data/refdata`.

| Module or feature | Expected reference data |
| --- | --- |
| Apptainer workflow containers | `/project/refdata/nextflow/.apptainer` |
| Binning with CheckM | `/project/refdata/checkM_DB` |
| Reads taxonomy: GOTTCHA | `/project/refdata/nextflow/database/GOTTCHA/GOTTCHA_BACTERIA_c4937_k24_u30_xHUMAN3x.genus`, `.species`, `.strain`; `/project/refdata/nextflow/database/GOTTCHA/GOTTCHA_VIRUSES_c5900_k24_u30_xHUMAN3x.genus`, `.species`, `.strain` |
| Reads taxonomy: GOTTCHA2 | `/project/refdata/GOTTCHA2/gottcha_db.species.fna` |
| Reads taxonomy: BWA | `/project/refdata/bwa_index/NCBI-Bacteria-Virus.fna` and its index sidecar files |
| Reads taxonomy: MetaPhlAn | `/project/refdata/metaphlan4` |
| Reads taxonomy: Kraken2 | `/project/refdata/Kraken2` |
| Reads taxonomy: PanGIA | `/project/refdata/PanGIA/NCBI_genomes_refseq86*.fa` |
| Reads taxonomy: DIAMOND | `/project/refdata/diamond/RefSeq_Release83.nr_protein_withRefSeq_viral_102317.protein.faa.dmnd` |
| Reads taxonomy: Centrifuge | `/project/refdata/Centrifuge/hpv.1.cf` and related Centrifuge index files |
| Contigs taxonomy and contigs-to-reference | `/project/refdata/miccrDB` |
| antiSMASH | `/project/refdata/antismash` |
| Reference-based analysis | `/project/refdata/bwa_index/NCBI-Bacteria-Virus.fna`, `id_mapping.txt` in the same directory, and `/project/refdata/NCBI_genomes` |
| SNP phylogeny | `/project/refdata/SNPdb`, `/project/refdata/bwa_index`, and `/project/refdata/NCBI_genomes` |
| Gene family and virulence analysis | `/project/refdata/RGI`, `/project/refdata/PathoFact2`, and `/project/refdata/genomad_db-v1.6` |
| Annotation KEGG viewer, when enabled | The configured `keggViewerDir` path for KEGG map data. |

If a workflow module fails with missing files, compare the generated project `nextflow.config` against this table and the selected module options in the UI.

## Quick Checks

```bash
./edgev3_app.sh check
find data/refdata -maxdepth 3 -type d | sort
find data/refdata -maxdepth 4 -type f | sort
```

For offline or restricted-network runs, pre-stage every required Apptainer image and reference database before submitting workflows.
