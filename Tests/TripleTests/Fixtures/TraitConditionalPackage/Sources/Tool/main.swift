#if SELECTED_FEATURE
let selectedFeature = "selected"
#else
let selectedFeature = "unselected"
#endif

#if DEFAULT_FEATURE
let defaultFeature = "+default"
#else
let defaultFeature = ""
#endif

print(selectedFeature + defaultFeature)
