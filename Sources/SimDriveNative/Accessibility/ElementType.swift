/// `XCUIElement.ElementType`, in raw-value order. Case names are the output spellings.
package enum ElementType: Int, Sendable {
    case any = 0, other, application, group, window, sheet, drawer, alert, dialog, button, radioButton, radioGroup
    case checkBox, disclosureTriangle, popUpButton, comboBox, menuButton, toolbarButton, popover, keyboard, key
    case navigationBar, tabBar, tabGroup, toolbar, statusBar, table, tableRow, tableColumn, outline, outlineRow
    case browser, collectionView, slider, pageIndicator, progressIndicator, activityIndicator, segmentedControl
    case picker, pickerWheel, `switch`, toggle, link, image, icon, searchField, scrollView, scrollBar, staticText
    case textField, secureTextField, datePicker, textView, menu, menuItem, menuBar, menuBarItem, map, webView
    case incrementArrow, decrementArrow, timeline, ratingIndicator, valueIndicator, splitGroup, splitter
    case relevanceIndicator, colorWell, helpTag, matte, dockItem, ruler, rulerMarker, grid, levelIndicator, cell
    case layoutArea, layoutItem, handle, stepper, tab, touchBar, statusItem
}
