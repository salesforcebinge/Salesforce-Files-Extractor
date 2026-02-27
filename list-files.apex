// =============================================================================
// Apex Anonymous: List ContentVersion files with optional size filtering
// Run in: Developer Console > Execute Anonymous | VS Code > SFDX: Execute Anonymous
//
// Use this to IDENTIFY files before downloading.
// Set minSizeMB = 0 to list ALL files.
// For actual download, use the companion bash script.
// =============================================================================

// --- Configuration ---
Integer minSizeMB = 0; // Set to 0 for ALL files, or any number (e.g. 5) to filter

// --- Query ---
List<ContentVersion> files;
if (minSizeMB > 0) {
    Integer minSizeBytes = minSizeMB * 1024 * 1024;
    files = [
        SELECT Id, Title, FileExtension, ContentSize,
               ContentDocumentId, Checksum, CreatedDate, Owner.Name
        FROM ContentVersion
        WHERE ContentSize > :minSizeBytes
        AND IsLatest = true
        ORDER BY ContentSize DESC
        LIMIT 2000
    ];
} else {
    files = [
        SELECT Id, Title, FileExtension, ContentSize,
               ContentDocumentId, Checksum, CreatedDate, Owner.Name
        FROM ContentVersion
        WHERE IsLatest = true
        ORDER BY ContentSize DESC
        LIMIT 2000
    ];
}

// --- Output ---
String filterLabel = (minSizeMB > 0) ? 'OVER ' + minSizeMB + ' MB' : 'ALL FILES';
System.debug(LoggingLevel.INFO,
    '\n=====================================' +
    '\n ' + filterLabel + ': ' + files.size() + ' found' +
    '\n=====================================');

Decimal totalSizeMB = 0;

for (ContentVersion cv : files) {
    Decimal sizeMB = (Decimal.valueOf(cv.ContentSize) / 1048576).setScale(2);
    totalSizeMB += sizeMB;

    System.debug(LoggingLevel.INFO,
        sizeMB + ' MB | ' +
        cv.Title + '.' + cv.FileExtension + ' | ' +
        'DocId: ' + cv.ContentDocumentId + ' | ' +
        'MD5: ' + cv.Checksum + ' | ' +
        'Owner: ' + cv.Owner.Name + ' | ' +
        'Created: ' + cv.CreatedDate
    );
}

System.debug(LoggingLevel.INFO,
    '\n=====================================' +
    '\n TOTAL: ' + files.size() + ' files, ' + totalSizeMB.setScale(1) + ' MB' +
    '\n=====================================');

// --- Optional: Output as CSV for copy-paste ---
System.debug(LoggingLevel.INFO, '\n--- CSV OUTPUT ---');
System.debug(LoggingLevel.INFO, 'ContentVersionId,ContentDocumentId,Title,Extension,SizeMB,Checksum,Owner,CreatedDate');
for (ContentVersion cv : files) {
    Decimal sizeMB = (Decimal.valueOf(cv.ContentSize) / 1048576).setScale(2);
    System.debug(LoggingLevel.INFO,
        cv.Id + ',' + cv.ContentDocumentId + ',"' + cv.Title + '",' +
        cv.FileExtension + ',' + sizeMB + ',' + cv.Checksum + ',"' + cv.Owner.Name + '",' + cv.CreatedDate
    );
}
