// altium_bridge.pas
// This script acts as a bridge between the MCP server and Altium
// It reads commands from a request JSON file, executes them, and writes results to a response JSON file

const
	constScriptProjectName = 'Altium_API'; // Define the script project name
    REPLACEALL = 1;
var
    RequestData : TStringList;
    ResponseData : TStringList;
	REQUEST_FILE : String;
    RESPONSE_FILE : String;
    ROOT_DIR: String;

{..............................................................................}
{ Initialize file paths using a fixed exchange directory.                      }
{ Both the Python MCP server and this script independently resolve to          }
{ C:\Users\Public\altium_mcp\ — avoiding fragile script-project-path          }
{ resolution that breaks when Altium caches stale script projects.             }
{..............................................................................}
procedure InitializeFilePaths();
begin
    ROOT_DIR := 'C:\Users\Public\altium_mcp\';

    // Create the directory if it doesn't exist
    if not DirectoryExists(ROOT_DIR) then
        ForceDirectories(ROOT_DIR);

    // Set the file paths
    REQUEST_FILE := ROOT_DIR + 'request.json';
    RESPONSE_FILE := ROOT_DIR + 'response.json';
end;

// Request parameters are read with the Req* helpers of json_utils.pas: they
// match top-level keys only and decode values, so commas, brackets, quotes
// and non-ASCII characters inside a value arrive intact.

function ExecuteGetComponentPins(RequestData: TStringList): String;
var
    DesignatorsList: TStringList;
begin
    DesignatorsList := TStringList.Create;
    try
        ReqArray(RequestData, 'designators', DesignatorsList);
        if DesignatorsList.Count > 0 then
            Result := GetComponentPinsFromList(ROOT_DIR, DesignatorsList)
        else
            Result := 'ERROR: No designators given for get_component_pins';
    finally
        DesignatorsList.Free;
    end;
end;

function ExecuteCreateNetClass(RequestData: TStringList): String;
var
    NetClassName: String;
    SourceList: TStringList;
begin
    SourceList := TStringList.Create;
    try
        NetClassName := ReqString(RequestData, 'class_name', '');
        ReqArray(RequestData, 'net_names', SourceList);
        if NetClassName = '' then
            Result := '{"success": false, "error": "No class name provided"}'
        else if SourceList.Count = 0 then
            Result := '{"success": false, "error": "No net names provided"}'
        else
            Result := CreateNetClass(NetClassName, SourceList);
    finally
        SourceList.Free;
    end;
end;

function ExecuteTakeViewScreenshot(RequestData: TStringList): String;
var
    DesignatorsList: TStringList;
begin
    DesignatorsList := TStringList.Create;
    try
        // Optional designators to zoom to before the capture
        ReqArray(RequestData, 'designators', DesignatorsList);
        Result := TakeViewScreenshot(ReqString(RequestData, 'view_type', 'pcb'), DesignatorsList);
    finally
        DesignatorsList.Free;
    end;
end;

function ExecuteCreateSchematicSymbol(RequestData: TStringList): String;
var
    ComponentName: String;
    PinsList: TStringList;
    GraphicsList: TStringList;
begin
    PinsList := TStringList.Create;
    GraphicsList := TStringList.Create;
    try
        ComponentName := ReqString(RequestData, 'symbol_name', '');
        // CreateSchematicSymbol takes the description as a 'Description='
        // entry ahead of the pins
        if (ReqLine(RequestData, 'description') >= 0) then
            PinsList.Add('Description=' + ReqString(RequestData, 'description', ''));
        ReqArray(RequestData, 'pins', PinsList);
        ReqArray(RequestData, 'graphics', GraphicsList);
        if ComponentName <> '' then
            Result := CreateSchematicSymbol(ComponentName, PinsList, GraphicsList,
                                            ReqInt(RequestData, 'part_count', 1))
        else
            Result := 'ERROR: No symbol name given for create_schematic_symbol';
    finally
        PinsList.Free;
        GraphicsList.Free;
    end;
end;

function ExecuteSetPCBLayerVisibility(RequestData: TStringList): String;
var
    SourceList: TStringList;
begin
    SourceList := TStringList.Create;
    try
        ReqArray(RequestData, 'layer_names', SourceList);
        if SourceList.Count > 0 then
            Result := SetPCBLayerVisibility(SourceList, ReqBool(RequestData, 'visible', False))
        else
            Result := '{"success": false, "error": "No layer names provided"}';
    finally
        SourceList.Free;
    end;
end;

function ExecuteSetComponentPosition(RequestData: TStringList): String;
var
    Designator: String;
begin
    Designator := ReqString(RequestData, 'designator', '');
    if Designator <> '' then
        // rotation -1 keeps the current rotation
        Result := SetComponentPosition(Designator,
                                       ReqFloat(RequestData, 'x', 0),
                                       ReqFloat(RequestData, 'y', 0),
                                       ReqFloat(RequestData, 'rotation', -1))
    else
        Result := 'ERROR: No designator given for set_component_position';
end;

function ExecuteMoveComponents(RequestData: TStringList): String;
var
    DesignatorsList: TStringList;
begin
    DesignatorsList := TStringList.Create;
    try
        ReqArray(RequestData, 'designators', DesignatorsList);
        if DesignatorsList.Count > 0 then
            Result := MoveComponentsByDesignators(DesignatorsList,
                          MilsToCoord(ReqFloat(RequestData, 'x_offset', 0)),
                          MilsToCoord(ReqFloat(RequestData, 'y_offset', 0)),
                          ReqFloat(RequestData, 'rotation', 0))
        else
            Result := 'ERROR: No designators given for move_components';
    finally
        DesignatorsList.Free;
    end;
end;

function ExecuteGetFootprintPrimitives(RequestData: TStringList): String;
begin
    Result := GetFootprintPrimitives(ROOT_DIR,
                                     ReqString(RequestData, 'library_path', ''),
                                     ReqString(RequestData, 'footprint_name', ''));
end;

function ExecuteCreateFootprintsBatch(RequestData: TStringList): String;
var
    SpecFile: String;
begin
    SpecFile := ReqString(RequestData, 'spec_file', '');
    if (SpecFile <> '') then
        Result := CreateFootprintsBatch(SpecFile)
    else
        Result := 'ERROR: No spec_file provided for create_footprints_batch';
end;

function ExecuteCreateSymbolsBatch(RequestData: TStringList): String;
var
    SpecFile: String;
begin
    SpecFile := ReqString(RequestData, 'spec_file', '');
    if (SpecFile <> '') then
        Result := CreateSymbolsBatch(SpecFile)
    else
        Result := 'ERROR: No spec_file provided for create_symbols_batch';
end;

function ExecuteGetSymbolPrimitives(RequestData: TStringList): String;
begin
    Result := GetSymbolPrimitives(ROOT_DIR,
                                  ReqString(RequestData, 'library_path', ''),
                                  ReqString(RequestData, 'symbol_name', ''));
end;

function ExecuteGetNetConnections(RequestData: TStringList): String;
var
    DesignatorsList: TStringList;
begin
    DesignatorsList := TStringList.Create;
    try
        // Optional: empty means the current selection
        ReqArray(RequestData, 'designators', DesignatorsList);
        Result := GetNetConnections(ROOT_DIR, DesignatorsList);
    finally
        DesignatorsList.Free;
    end;
end;

function ExecuteCheckPlacement(RequestData: TStringList): String;
var
    DesignatorsList: TStringList;
begin
    DesignatorsList := TStringList.Create;
    try
        // Optional: empty means the current selection
        ReqArray(RequestData, 'designators', DesignatorsList);
        Result := CheckPlacement(DesignatorsList, ReqFloat(RequestData, 'clearance_mils', 6));
    finally
        DesignatorsList.Free;
    end;
end;

function ExecutePlaceComponents(RequestData: TStringList): String;
var
    PlacementsList: TStringList;
begin
    // Placements arrive as pipe-delimited strings 'Designator|X|Y|Rotation|Layer'
    PlacementsList := TStringList.Create;
    try
        ReqArray(RequestData, 'placements', PlacementsList);
        if PlacementsList.Count > 0 then
            Result := PlaceComponentsFromList(PlacementsList)
        else
            Result := 'ERROR: No placements provided for place_components';
    finally
        PlacementsList.Free;
    end;
end;

function ExecuteLayoutDuplicatorApply(RequestData: TStringList): String;
var
    SourceList, DestList: TStringList;
begin
    SourceList := TStringList.Create;
    DestList := TStringList.Create;
    try
        ReqArray(RequestData, 'source_designators', SourceList);
        ReqArray(RequestData, 'destination_designators', DestList);
        if (SourceList.Count > 0) and (DestList.Count > 0) then
            Result := ApplyLayoutDuplicator(SourceList, DestList)
        else
            Result := '{"success": false, "error": "Source or destination lists are empty"}';
    finally
        SourceList.Free;
        DestList.Free;
    end;
end;

function ExecuteGetOutputJobContainers(RequestData: TStringList): String;
begin
    Result := GetOutputJobContainers(ROOT_DIR, ReqString(RequestData, 'outjob_path', ''));
end;

function ExecuteRunOutputJobs(RequestData: TStringList): String;
var
    ContainersList: TStringList;
begin
    ContainersList := TStringList.Create;
    try
        ReqArray(RequestData, 'container_names', ContainersList);
        if ContainersList.Count > 0 then
            Result := RunOutputJobs(ContainersList, ROOT_DIR, ReqString(RequestData, 'outjob_path', ''))
        else
            Result := '{"success": false, "error": "No container names specified"}';
    finally
        ContainersList.Free;
    end;
end;

function ExecuteCreatePCBFootprint(RequestData: TStringList): String;
var
    FootprintName: String;
    PadsList: TStringList;
begin
    PadsList := TStringList.Create;
    try
        FootprintName := ReqString(RequestData, 'footprint_name', '');
        ReqArray(RequestData, 'pads', PadsList);
        if FootprintName <> '' then
            Result := CreatePCBFootprint(FootprintName,
                                         ReqString(RequestData, 'description', ''),
                                         PadsList,
                                         ReqFloat(RequestData, 'courtyard_x_mm', 0),
                                         ReqFloat(RequestData, 'courtyard_y_mm', 0))
        else
            Result := '{"success": false, "error": "No footprint name provided"}';
    finally
        PadsList.Free;
    end;
end;

function ExecuteSearchLibrarySymbol(RequestData: TStringList): String;
var
    SymbolName: String;
begin
    SymbolName := ReqString(RequestData, 'symbol_name', '');
    if SymbolName <> '' then
        Result := SearchLibrarySymbol(ROOT_DIR, ReqString(RequestData, 'library_path', ''), SymbolName)
    else
        Result := 'ERROR: No symbol name provided for search_library_symbol';
end;

function ExecuteGetERCViolations(RequestData: TStringList): String;
begin
    Result := GetERCViolations(ROOT_DIR, ReqBool(RequestData, 'compile', True));
end;

function ExecuteGetComponentPrimitives(RequestData: TStringList): String;
var
    DesignatorsList: TStringList;
begin
    DesignatorsList := TStringList.Create;
    try
        ReqArray(RequestData, 'designators', DesignatorsList);
        if DesignatorsList.Count > 0 then
            Result := GetComponentPrimitivesFromList(ROOT_DIR, DesignatorsList)
        else
            Result := 'ERROR: No designators given for get_component_primitives';
    finally
        DesignatorsList.Free;
    end;
end;

function ExecuteGetProjectComponents(RequestData: TStringList): String;
begin
    Result := GetProjectComponents(ROOT_DIR, ReqBool(RequestData, 'include_parameters', False));
end;

// Function to execute a command with parameters
function ExecuteCommand(CommandName: String): String;
var
    ViewHint   : String;
begin
    Result := '';

    // take_view_screenshot can target a PCB or a schematic. Pull view_type out
    // of the request so the focus helper does not always demand a PCB.
    ViewHint := '';
    if CommandName = 'take_view_screenshot' then
        ViewHint := LowerCase(ReqString(RequestData, 'view_type', ''));

    // A focus failure is an answer, not a dialog: WriteResponse turns the
    // 'ERROR: ' prefix into success=false with this message.
    if not EnsureDocumentFocused(CommandName, ViewHint) then
    begin
        Result := 'ERROR: ' + FocusFailure;
        Exit;
    end;

    // Direct command execution based on the command name
    case CommandName of
        'get_component_pins':
            Result := ExecuteGetComponentPins(RequestData);            
        'get_all_nets':
            Result := GetAllNets(ROOT_DIR);            
        'create_net_class':
            Result := ExecuteCreateNetClass(RequestData);            
        'get_all_component_data':
            Result := GetAllComponentData(ROOT_DIR, False);            
        'take_view_screenshot':
            Result := ExecuteTakeViewScreenshot(RequestData);            
        'get_library_symbol_reference':
            Result := GetLibrarySymbolReference(ROOT_DIR);            
        'create_schematic_symbol':
            Result := ExecuteCreateSchematicSymbol(RequestData);            
        'get_schematic_data':
            Result := GetSchematicData(ROOT_DIR);            
        'get_pcb_layers':
            Result := GetPCBLayers(ROOT_DIR);            
        'set_pcb_layer_visibility':
            Result := ExecuteSetPCBLayerVisibility(RequestData);   
        'get_pcb_layer_stackup':
            Result := GetPCBLayerStackup(ROOT_DIR);         
        'get_selected_components_coordinates':
            Result := GetSelectedComponentsCoordinates(ROOT_DIR); 
		'set_component_position':
			Result := ExecuteSetComponentPosition(RequestData);
        'move_components':
            Result := ExecuteMoveComponents(RequestData);
        'place_components':
            Result := ExecutePlaceComponents(RequestData);
        'check_placement':
            Result := ExecuteCheckPlacement(RequestData);
        'get_net_connections':
            Result := ExecuteGetNetConnections(RequestData);
        'get_symbol_primitives':
            Result := ExecuteGetSymbolPrimitives(RequestData);
        'create_symbols_batch':
            Result := ExecuteCreateSymbolsBatch(RequestData);
        'build_circuit':
            Result := BuildCircuitFromSpec(ROOT_DIR + 'circuit_spec.txt',
                                          ROOT_DIR + 'param_placement.txt');
        'get_footprint_primitives':
            Result := ExecuteGetFootprintPrimitives(RequestData);
        'create_footprints_batch':
            Result := ExecuteCreateFootprintsBatch(RequestData);
        'layout_duplicator':
            Result := GetLayoutDuplicatorComponents(True);            
        'layout_duplicator_apply':
            Result := ExecuteLayoutDuplicatorApply(RequestData);            
        'get_pcb_rules':
            Result := GetPCBRules(ROOT_DIR);
        'get_output_job_containers':
            Result := ExecuteGetOutputJobContainers(RequestData);
        'run_output_jobs':
            Result := ExecuteRunOutputJobs(RequestData);
        'search_library_symbol':
            Result := ExecuteSearchLibrarySymbol(RequestData);
        'create_pcb_footprint':
            Result := ExecuteCreatePCBFootprint(RequestData);
        'get_project_info':
            Result := GetProjectInfo(ROOT_DIR);
        'get_project_components':
            Result := ExecuteGetProjectComponents(RequestData);
        'get_erc_violations':
            Result := ExecuteGetERCViolations(RequestData);
        'get_board_summary':
            Result := GetBoardSummary(ROOT_DIR);
        'get_component_primitives':
            Result := ExecuteGetComponentPrimitives(RequestData);
        'close_sandbox_editor':
            Result := CloseSandboxEditor(0);
    else
        Result := 'ERROR: Unknown command: ' + CommandName;
    end;
end;

// Write the answer for the server. The server waits for
// response_<request_id>.json, so a late answer to an earlier, timed-out
// request can never be taken for the current one.
procedure WriteResponse(Success: Boolean; Data: String; ErrorMsg: String; RequestId: String);
var
    ActualSuccess: Boolean;
    ActualErrorMsg: String;
    ResultProps: TStringList;
begin
    // Check if Data contains an error message
    if (Pos('ERROR:', Data) = 1) then
    begin
        ActualSuccess := False;
        ActualErrorMsg := Trim(Copy(Data, 7, Length(Data))); // Remove 'ERROR:' prefix
    end
    else
    begin
        ActualSuccess := Success;
        ActualErrorMsg := ErrorMsg;
    end;

    ResultProps := TStringList.Create;
    ResponseData := TStringList.Create;
    try
        AddJSONProperty(ResultProps, 'request_id', RequestId);
        AddJSONBoolean(ResultProps, 'success', ActualSuccess);

        if ActualSuccess then
        begin
            // For JSON responses (starting with [ or {), don't wrap in additional quotes
            if (Length(Data) > 0) and ((Data[1] = '[') or (Data[1] = '{')) then
                ResultProps.Add(JSONPairStr('result', Data, False))
            else
                AddJSONProperty(ResultProps, 'result', Data);
        end
        else
        begin
            AddJSONProperty(ResultProps, 'error', ActualErrorMsg);
        end;

        ResponseData.Text := BuildJSONObject(ResultProps);
        if (RequestId <> '') then
            ResponseData.SaveToFile(ROOT_DIR + 'response_' + RequestId + '.json')
        else
            ResponseData.SaveToFile(RESPONSE_FILE);
    finally
        ResultProps.Free;
        ResponseData.Free;
    end;
end;

// Main procedure to run the bridge
procedure Run;
var
    CommandType: String;
    Result: String;
    RequestId: String;
begin
    InitializeFilePaths();

    // No request means an earlier launch of this script already consumed it:
    // when Altium was busy the server's RunScript calls can queue up, and the
    // later ones must not execute the same command a second time
    if not FileExists(REQUEST_FILE) then
    begin
        LogScriptError('No request file at ' + REQUEST_FILE + ' (already handled by an earlier run)');
        Exit;
    end;

    RequestId := '';
    try
        RequestData := TStringList.Create;
        try
            RequestData.LoadFromFile(REQUEST_FILE);
            DeleteFile(REQUEST_FILE);

            RequestId := ReqString(RequestData, 'request_id', '');
            CommandType := ReqString(RequestData, 'command', '');

            if CommandType <> '' then
            begin
                Result := ExecuteCommand(CommandType);

                if Result <> '' then
                    WriteResponse(True, Result, '', RequestId)
                else
                begin
                    WriteResponse(False, '', 'Command ' + CommandType + ' failed without a message '
                                  + '(see C:\Users\Public\altium_mcp\script_errors.log)', RequestId);
                    LogScriptError('Error: Command execution failed: ' + CommandType);
                end;
            end
            else
            begin
                WriteResponse(False, '', 'No command specified', RequestId);
                LogScriptError('Error: No command specified');
            end;
        finally
            RequestData.Free;
        end;
    except
        WriteResponse(False, '', 'Exception occurred during script execution', RequestId);
        LogScriptError('Error: Exception occurred during script execution');
    end;
end;
