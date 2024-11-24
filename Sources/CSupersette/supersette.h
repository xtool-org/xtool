#include <stdint.h>

void supersette_Load(const char *path);
int32_t supersette_SetAndroidID(const char *identifier, uint32_t length);
int32_t supersette_SetProvisioningPath(const char *path);
int32_t supersette_ProvisioningErase(uint64_t dsId);
int32_t supersette_Synchronize(uint64_t dsId, const void *serverIntermediateMetadata, uint32_t serverIntermediateMetadataLength, void **machineIdentifier, uint32_t *machineIdentifierLength, void **synchronizationResumeMetadata, uint32_t *synchronizationResumeMetadataLength);
int32_t supersette_ProvisioningDestroy(uint32_t session);
int32_t supersette_ProvisioningEnd(uint32_t session, const void *persistentTokenMetadata, uint32_t persistentTokenMetadataLength, const void *trustKey, uint32_t trustKeyLength);
int32_t supersette_ProvisioningStart(uint64_t dsId, const void *serverProvisioningIntermediateMetadata, uint32_t serverProvisioningIntermediateMetadataLength, void **clientProvisioningIntermediateMetadata, uint32_t *clientProvisioningIntermediateMetadataLength, uint32_t *session);
int32_t supersette_GetLoginCode(uint64_t dsId);
int32_t supersette_Dispose(void *ptr);
int32_t supersette_OTPRequest(uint64_t dsId, void **machineIdentifier, uint32_t *machineIdentifierLength, void **oneTimePassword, uint32_t *oneTimePasswordLength);
