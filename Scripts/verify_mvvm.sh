#!/bin/zsh
set -eu
cd "${0:A:h:h}"
swiftc -module-cache-path /tmp/HomeMateMVVMModuleCache \
  HomeMate/Models/*.swift HomeMate/Repositories/HouseholdStore.swift HomeMate/Repositories/HouseholdContext.swift \
  HomeMate/Services/{CloudAccount,FirebaseHouseholdAPI,FamilyAPI,ExpenseML,CalendarExportService}.swift \
  HomeMate/ViewModels/{ScreenViewModel,WelcomeViewModel,SettingsViewModel,MoreViewModel,NavigationViewModel,RecordsViewModel,RecordEditorViewModel,DashboardViewModel,CalendarViewModel,LoginViewModel,CloudRecordsViewModel,SharedFamilyViewModel,SharedFamilyChatViewModel}.swift \
  Scripts/verify_mvvm.swift -o /tmp/HomeMateMVVMCheck
/tmp/HomeMateMVVMCheck
