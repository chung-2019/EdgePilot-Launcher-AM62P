# Stub: declare we have Qt6QuickTools.
# Qt 6.4 host doesn't ship a separate QuickTools package, but for our use case
# (cross-compile against Qt 6.12 target) we don't actually invoke quicktools binaries,
# only need cmake to consider the dependency satisfied.
set(Qt6QuickTools_FOUND TRUE)
set(QT_KNOWN_POLICY_QTP0001 TRUE)
