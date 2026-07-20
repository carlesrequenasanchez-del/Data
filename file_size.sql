SELECT 
    CASE 
        WHEN file_format IN ('DOC','doc','docx') THEN 'doc'
        WHEN file_format IN ('CSV') THEN 'csv'
        WHEN file_format IN ('jpeg', 'JPEG', 'jpg', 'JPG') THEN 'jpg'
        WHEN file_format IN ('pdf', 'Pdf', 'PDF') THEN 'pdf'
        WHEN file_format IN ('png', 'PNG') THEN 'png'
        WHEN file_format IN ('ppt', 'PPT', 'pptx', 'PPTX') THEN 'ppt'
        WHEN file_format IN ('xls', 'xlsx') THEN 'excel'
        ELSE 'others' 
    END AS file_format,
    COUNT(id) AS cantidad,
    ROUND(AVG(
        CASE
            WHEN file_size ILIKE '%MB' 
                THEN CAST(REPLACE(file_size, 'MB', '') AS NUMERIC)
            WHEN file_size ILIKE '%KB' 
                THEN CAST(REPLACE(file_size, 'KB', '') AS NUMERIC) / 1024
        END
    ), 2) AS avg_size_mb
FROM files f 
WHERE created_at between '2025-01-01' and '2026-03-01'
GROUP BY 1