
-- Fremmed nøgler
ALTER TABLE dbo.fact_udbud
  ADD CONSTRAINT fk_fact_lot FOREIGN KEY (objekt_id) REFERENCES
  dbo.dim_lot(objekt_id);

ALTER TABLE dbo.fact_udbud
  ADD CONSTRAINT fk_fact_auktion FOREIGN KEY (auktion_id) REFERENCES
  dbo.dim_auktion(auktion_id);

ALTER TABLE dbo.fact_udbud
  ADD CONSTRAINT fk_fact_dato FOREIGN KEY (auktionsdato_key) REFERENCES
  dbo.dim_dato(date_key);

CREATE INDEX ix_fact_objekt_id
  ON dbo.fact_udbud(objekt_id);

CREATE INDEX ix_fact_auktion_id
  ON dbo.fact_udbud(auktion_id);

CREATE INDEX ix_fact_dato_key
  ON dbo.fact_udbud(auktionsdato_key); 


-- Rækketal – forvent 184377 / 158930 / 874 / 2038
SELECT 'fact_udbud' AS tabel, COUNT(*) AS raekker FROM dbo.fact_udbud
UNION ALL SELECT 'dim_lot',     COUNT(*) FROM dbo.dim_lot
UNION ALL SELECT 'dim_auktion', COUNT(*) FROM dbo.dim_auktion
UNION ALL SELECT 'dim_dato',    COUNT(*) FROM dbo.dim_dato;


-- Forældreløse fremmednøgler – forvent 0 i alle
SELECT COUNT(*) AS foraeldreloese_lot
FROM dbo.fact_udbud f LEFT JOIN dbo.dim_lot d ON f.objekt_id = d.objekt_id
WHERE d.objekt_id IS NULL;

SELECT COUNT(*) AS foraeldreloese_auktion
FROM dbo.fact_udbud f LEFT JOIN dbo.dim_auktion a ON f.auktion_id = a.auktion_id
WHERE a.auktion_id IS NULL;


 --Forretningsregel: solgt -> hammerslag skal findes; usolgt => skal være NULL
SELECT
    SUM(CASE WHEN solgt_flag = 1 AND hammerslag IS NULL THEN 1 ELSE 0 END) AS solgt_uden_hammerslag,
    SUM(CASE WHEN solgt_flag = 0 AND hammerslag IS NOT NULL THEN 1 ELSE 0 END) AS usolgt_med_hammerslag
FROM dbo.fact_udbud;   -- forvent 0 / 0


-- NULL-mønster i faktatabellen (dokumentation af den åbne kohorte)
SELECT COUNT(*) AS antal_lots,
       SUM(CASE WHEN hammerslag IS NULL THEN 1 ELSE 0 END) AS uden_hammerslag,
       AVG(CAST(solgt_flag AS DECIMAL(4,3)))               AS sell_through
FROM dbo.fact_udbud;
GO

-- KPI Dekomponering	
CREATE OR ALTER VIEW dbo.vw_kpi_dekomponering AS

WITH udbud AS
  (SELECT d.aar,
          a.auktionstype AS kanal,
          l.hovedkategori,
          l.underkategori,
          f.solgt_flag,
          f.min_vurdering,
          cast((f.min_vurdering + f.max_vurdering) / 2.0 AS decimal(10, 2)) AS midt_vurdering,
          f.hammerslag,
          cast(f.hammerslag * f.salaer_sats AS decimal(10, 2)) AS salaer_kr
   FROM fact_udbud AS f
   JOIN dim_lot AS l ON f.objekt_id = l.objekt_id
   JOIN dim_auktion AS a ON f.auktion_id = a.auktion_id
   JOIN dim_dato AS d ON f.auktionsdato_key = d.date_key)
SELECT aar,
       kanal,
       hovedkategori,
       underkategori,
       count(*) AS antal_udbud,
       sum(cast(solgt_flag AS INT)) AS antal_solgt,
       cast(avg(cast(solgt_flag AS decimal(6, 2))) AS decimal(6, 2)) AS sell_through,
       sum(CASE
               WHEN solgt_flag = 1 THEN hammerslag
           END) AS sum_hammerslag,
       sum(CASE
               WHEN solgt_flag = 1 THEN min_vurdering
           END) AS sum_min_vurd,
       sum(CASE
               WHEN solgt_flag = 1 THEN midt_vurdering
           END) AS sum_midt_vurd,
       sum(salaer_kr) AS sum_salaer_kr,
       cast(sum(CASE
                    WHEN solgt_flag = 1 THEN hammerslag
                END) * 1.0 / nullif(sum(CASE
                                            WHEN solgt_flag = 1 THEN midt_vurdering
                                        END), 0) AS decimal(6, 2)) AS realiserings_grad
FROM udbud
GROUP BY aar,
         kanal,
         hovedkategori,
         underkategori -- order by aar asc
GO

-- Genbuds analyse
CREATE OR ALTER VIEW dbo.vw_genudbud AS
WITH forloeb AS (
    SELECT
        f.lot_nr,
        f.objekt_id,
        f.auktion_id,
        a.auktionstype   AS kanal,
        d.dato           AS auktionsdato,
        f.genudbud_nr,
        f.solgt_flag,
        f.mindstepris,
        f.hammerslag,
        ROW_NUMBER() OVER (PARTITION BY f.objekt_id ORDER BY f.auktionsdato_key)
            AS forsoeg_nr,
        COUNT(*)     OVER (PARTITION BY f.objekt_id)
            AS antal_udbud_i_alt,
        LAG(a.auktionstype) OVER (PARTITION BY f.objekt_id ORDER BY f.auktionsdato_key)
            AS forrige_kanal,
        LAG(f.mindstepris)  OVER (PARTITION BY f.objekt_id ORDER BY f.auktionsdato_key)
            AS forrige_mindstepris,
        LAG(d.dato)         OVER (PARTITION BY f.objekt_id ORDER BY f.auktionsdato_key)
            AS forrige_auktionsdato
    FROM dbo.fact_udbud   AS f
    JOIN dbo.dim_auktion  AS a ON f.auktion_id       = a.auktion_id
    JOIN dbo.dim_dato     AS d ON f.auktionsdato_key = d.date_key
)
SELECT
    lot_nr,
    objekt_id,
    auktion_id,
    kanal,
    auktionsdato,
    forsoeg_nr,
    antal_udbud_i_alt,
    genudbud_nr,                     -- gemt værdi; bør matche forsoeg_nr
    solgt_flag,
    mindstepris,
    hammerslag,
    forrige_kanal,
    CASE WHEN forrige_kanal IS NOT NULL AND forrige_kanal <> kanal
         THEN 1 ELSE 0 END           AS kanal_skift,
    forrige_mindstepris,
    mindstepris - forrige_mindstepris AS mindstepris_aendring,
    CAST((mindstepris - forrige_mindstepris) * 1.0
         / NULLIF(forrige_mindstepris, 0) AS DECIMAL(9,4)) AS mindstepris_pct_aendring,
    DATEDIFF(DAY, forrige_auktionsdato, auktionsdato)      AS dage_siden_forrige
FROM forloeb;
GO

-- Værdiklasse matrix
CREATE OR ALTER VIEW dbo.vw_vaerdiklasse_matrix AS
WITH solgte AS (
    SELECT
        vaerdiklasse_vurderet   AS kl_vurderet,
        vaerdiklasse_realiseret AS kl_realiseret,
        CASE vaerdiklasse_vurderet
             WHEN '<2.000' THEN 1 WHEN '2.000-10.000' THEN 2
             WHEN '10.000-50.000' THEN 3 WHEN '50.000-250.000' THEN 4
             WHEN '>250.000' THEN 5 END AS sort_vurderet,
        CASE vaerdiklasse_realiseret
             WHEN '<2.000' THEN 1 WHEN '2.000-10.000' THEN 2
             WHEN '10.000-50.000' THEN 3 WHEN '50.000-250.000' THEN 4
             WHEN '>250.000' THEN 5 END AS sort_realiseret,
        hammerslag
    FROM dbo.fact_udbud
    WHERE solgt_flag = 1
)
SELECT
    kl_vurderet   AS vaerdiklasse_vurderet,
    kl_realiseret AS vaerdiklasse_realiseret,
    sort_vurderet,
    sort_realiseret,
    CASE WHEN sort_realiseret = sort_vurderet THEN 'Samme'
         WHEN sort_realiseret >  sort_vurderet THEN 'Op'
         ELSE 'Ned' END                       AS retning,
    COUNT(*)        AS antal_lots,
    SUM(hammerslag) AS sum_hammerslag,
    CAST(100.0 * COUNT(*)
         / SUM(COUNT(*)) OVER (PARTITION BY kl_vurderet)
         AS DECIMAL(5,2))                      AS pct_af_vurderet_klasse
FROM solgte
GROUP BY kl_vurderet, kl_realiseret, sort_vurderet, sort_realiseret;
GO


















