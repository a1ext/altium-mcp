const
    DEFAULT = 'Blank';
    SCRIPT_ERROR_LOG = 'C:\Users\Public\altium_mcp\script_errors.log';

var
    // Why the last EnsureDocumentFocused call failed; reported to the server.
    FocusFailure : String;

// Errors must never be modal. The server is driven by an agent with no hands:
// a ShowMessage box blocks this script before it writes its response, every
// later request then times out, and Altium reports "another instance is
// busy" until a human clicks OK. Log instead; the caller returns the error.
procedure LogScriptError(Msg: String);
var
    L : TStringList;
begin
    L := TStringList.Create;
    try
        if FileExists(SCRIPT_ERROR_LOG) then L.LoadFromFile(SCRIPT_ERROR_LOG);
        L.Add(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + '  ' + Msg);
        while L.Count > 500 do L.Delete(0);
        L.SaveToFile(SCRIPT_ERROR_LOG);
    except
    end;
end;

// The design project the user works in. A script always sees "Free
// Documents" or its own script project as DM_FocusedProject, so prefer the
// project owning the active document, then the focused project if it is a
// PCB project, then the first open PCB project.
function GetActiveProject(Dummy: Integer): IProject;
var
    WS       : IWorkspace;
    Prj      : IProject;
    i, j     : Integer;
    DocPath  : String;
begin
    Result := nil;
    WS := GetWorkspace;
    if (WS = nil) then Exit;
    DocPath := '';
    if (Client.CurrentView <> nil) then
        if (Client.CurrentView.OwnerDocument <> nil) then
            DocPath := LowerCase(Client.CurrentView.OwnerDocument.FileName);
    if (DocPath <> '') then
        for j := 0 to WS.DM_ProjectCount - 1 do
        begin
            Prj := WS.DM_Projects(j);
            for i := 0 to Prj.DM_LogicalDocumentCount - 1 do
                if (LowerCase(Prj.DM_LogicalDocuments(i).DM_FullPath) = DocPath) then
                begin
                    Result := Prj;
                    Exit;
                end;
        end;
    Prj := WS.DM_FocusedProject;
    if (Prj <> nil) then
        if (UpperCase(ExtractFileExt(Prj.DM_ProjectFullPath)) = '.PRJPCB') then
        begin
            Result := Prj;
            Exit;
        end;
    for j := 0 to WS.DM_ProjectCount - 1 do
        if (UpperCase(ExtractFileExt(WS.DM_Projects(j).DM_ProjectFullPath)) = '.PRJPCB') then
        begin
            Result := WS.DM_Projects(j);
            Exit;
        end;
    Result := Prj;
end;

// Close the script editor's copies of the MCP's own script units. When a
// script crashes, the debugger opens its unit in the editor, and from then
// on RunScript runs that editor buffer instead of the file on disk: for the
// sandbox an old script (or one that exits at once because its start marker
// is gone), for the bridge units the code from before an extension update.
// Unmodified copies only: closing a modified one would ask to save.
// Answering at all also proves the script executor is alive.
function CloseSandboxEditor(Dummy: Integer): String;
var
    i, j, Closed, Kept : Integer;
    M      : IServerModule;
    D      : IServerDocument;
    Found  : Boolean;
begin
    Closed := 0;
    Kept := 0;
    Found := True;
    while Found and (Closed < 10) do
    begin
        Found := False;
        D := nil;
        for i := 0 to Client.Count - 1 do
        begin
            M := Client.ServerModule[i];
            if (M <> nil) then
                for j := 0 to M.DocumentCount - 1 do
                    if (D = nil) then
                        if (M.Documents[j].Kind = 'EDITSCRIPTDS') then
                            if (Pos('\SANDBOXSCRIPT\', UpperCase(M.Documents[j].FileName)) > 0) or
                               (Pos('\ALTIUMSCRIPT\', UpperCase(M.Documents[j].FileName)) > 0) then
                            begin
                                if M.Documents[j].Modified then
                                    Kept := Kept + 1
                                else
                                    D := M.Documents[j];
                            end;
        end;
        if (D <> nil) then
        begin
            Client.CloseDocument(D);
            Closed := Closed + 1;
            Found := True;
            Kept := 0;
        end;
    end;
    Result := '{"closed": ' + IntToStr(Closed) + ', "kept_modified": ' + IntToStr(Kept) + '}';
end;

// True when a PCB (not a footprint library) is the document in front.
// GetBoardSafe also finds boards open behind other tabs, which is right for
// reading and editing but wrong for screenshots and zooming.
function PcbInFront(Dummy: Integer): Boolean;
var
    Board : IPCB_Board;
begin
    Result := False;
    if (PCBServer = nil) then Exit;
    Board := PCBServer.GetCurrentPCBBoard;
    if (Board = nil) then Exit;
    Result := not Board.IsLibrary;
end;

{..............................................................................}
{ Get path of this script project.                                             }
{ Get prj path from Jeff Collins and William Kitchen's stripped down version   }
{..............................................................................}
function ScriptProjectPath(Workspace: IWorkspace) : String;
var
  Project   : IProject;
  scriptsPath : TDynamicString;
  candidatePath : TDynamicString;
  rootDir : TDynamicString;
  projectCount : Integer;
  i      : Integer;
begin
  if (Workspace = nil) then begin result:=''; exit; end;
  { Get a count of the number of currently opened projects.  The script project
    from which this script runs must be one of these. }
  projectCount := Workspace.DM_ProjectCount();
  { Loop over all the open projects.  We're looking for constScriptProjectName
    (of which we are a part).  Once we find this, we want to record the
    path to the script project directory.
    If multiple projects match (e.g. stale copies cached by Altium), prefer
    the one whose ROOT_DIR contains request.json — since the MCP server
    writes request.json before launching, only the active copy will have it. }
  scriptsPath:='';
  for i:=0 to projectCount-1 do
  begin
    { Get reference to project # i. }
    Project := Workspace.DM_Projects(i);
    { See if we found our script project. }
    if (AnsiPos(constScriptProjectName, Project.DM_ProjectFullPath) > 0) then
    begin
      { Strip off project name to give us just the path. }
      candidatePath := StringReplace(Project.DM_ProjectFullPath, '\' +
      constScriptProjectName + '.PrjScr','', MkSet(rfReplaceAll,rfIgnoreCase));

      { Check if request.json exists at this candidate's ROOT_DIR }
      rootDir := ExtractFilePath(ExtractFilePath(candidatePath));
      if FileExists(rootDir + 'request.json') then
      begin
        { Found the active copy — use it immediately }
        result := candidatePath;
        exit;
      end;

      { Keep as fallback in case no candidate has request.json }
      if scriptsPath = '' then
        scriptsPath := candidatePath;
    end;
  end;
  result := scriptsPath;
end;

// Find the first open OutJob document
function GetOpenOutputJob(): String;
var
    Project     : IProject;
    ProjectIdx, I  : Integer;
    Doc: IDocument;
    DocKind: String;
begin
    result := '';
    for ProjectIdx := 0 to GetWorkspace.DM_ProjectCount - 1 do
    begin
        Project := GetWorkspace.DM_Projects(ProjectIdx);
        if Project = Nil then Exit;

        // Iterate all documents in the project
        for I := 0 to Project.DM_LogicalDocumentCount - 1 do
        begin
            Doc := Project.DM_LogicalDocuments(I);
            DocKind := Doc.DM_DocumentKind;
            if DocKind = 'OUTPUTJOB' then
            begin
                result := Doc.DM_FullPath;
                Exit;
            end;
        end;
    end;
end;

// Return the Index-th (0-based) field of a pipe-delimited string,
// e.g. GetFieldFromPipeString('R1|100|200', 1) = '100'.
// Returns '' if the field does not exist.
function GetFieldFromPipeString(S: String; Index: Integer): String;
var
    i, FieldStart, FieldIndex: Integer;
begin
    Result := '';
    FieldIndex := 0;
    FieldStart := 1;
    for i := 1 to Length(S) do
    begin
        if S[i] = '|' then
        begin
            if FieldIndex = Index then
            begin
                Result := Copy(S, FieldStart, i - FieldStart);
                Exit;
            end;
            FieldIndex := FieldIndex + 1;
            FieldStart := i + 1;
        end;
    end;
    if FieldIndex = Index then
        Result := Copy(S, FieldStart, Length(S) - FieldStart + 1);
end;

// Modify the EnsureDocumentFocused function to handle all document types
// and return more detailed information.
// ViewTypeHint is only consulted by commands that can target more than one
// document kind (currently take_view_screenshot); pass '' otherwise.
function EnsureDocumentFocused(CommandName: String; ViewTypeHint: String): Boolean;
var
    I           : Integer;
    P           : Integer;
    Project     : IProject;
    Doc         : IDocument;
    DocFound    : Boolean;
    CurrentDoc  : IServerDocument;
    DocumentKind: String;
    LogMessage  : String;
    OutJobPath: String;
begin
    Result := False;
    DocFound := False;
    DocumentKind := 'PCB'; // Default

    // Commands that handle their own document management - skip focusing
    if (CommandName = 'search_library_symbol') or
       (CommandName = 'build_circuit') or
       (CommandName = 'get_symbol_primitives') or
       (CommandName = 'create_symbols_batch') or
       (CommandName = 'get_footprint_primitives') or
       (CommandName = 'create_footprints_batch') or
       (CommandName = 'create_pcb_footprint') or
       (CommandName = 'get_project_info') or
       (CommandName = 'get_project_components') or
       (CommandName = 'get_erc_violations') or
       (CommandName = 'close_sandbox_editor') or
       // The OutJob commands find (ResolveOutJob) and open their OutJob
       // themselves, also one given by path that no project contains
       (CommandName = 'get_output_job_containers') or
       (CommandName = 'run_output_jobs') then
    begin
        Result := True;
        Exit;
    end;

    // For PCB-related commands, ensure PCB is available first
    if (CommandName = 'create_net_class')                    or
       (CommandName = 'get_all_component_data')              or
       (CommandName = 'get_all_components')                  or
       (CommandName = 'get_all_nets')                        or
       (CommandName = 'get_component_pins')                  or
       (CommandName = 'get_pcb_layers')                      or
       (CommandName = 'get_pcb_rules')                       or
       (CommandName = 'get_selected_components_coordinates') or
       (CommandName = 'layout_duplicator')                   or
       (CommandName = 'layout_duplicator_apply')             or
       (CommandName = 'move_components')                     or
       (CommandName = 'place_components')                    or
       (CommandName = 'check_placement')                     or
       (CommandName = 'get_net_connections')                 or
       (CommandName = 'set_component_position')              or
       (CommandName = 'set_pcb_layer_visibility')            or
       (CommandName = 'get_pcb_layer_stackup')               or
       (CommandName = 'get_board_summary')                   or
       (CommandName = 'get_component_primitives')            then
    begin
        DocumentKind := 'PCB';
    end
    // Screenshots can target either domain - follow the caller's view_type
    // instead of always demanding a PCB.
    else if (CommandName = 'take_view_screenshot') then
    begin
        if LowerCase(ViewTypeHint) = 'sch' then
            DocumentKind := 'SCH'
        else
            DocumentKind := 'PCB';
    end
    else if (CommandName = 'create_schematic_symbol')        or
            (CommandName = 'get_library_symbol_reference')   then
    begin
        DocumentKind := 'SCHLIB';
    end
    else if (CommandName = 'create_pcb_footprint') then
    begin
        DocumentKind := 'PCBLIB';
    end
    else if (CommandName = 'get_schematic_data')             then
    begin
        DocumentKind := 'SCH';
    end
    else if (CommandName = 'get_output_job_containers')       or
            (CommandName = 'run_output_jobs')                then
    begin
        DocumentKind := 'OUTJOB';
    end;
    // Default to user argument if command not recognized

    LogMessage := 'Attempting to focus ' + DocumentKind + ' document';
    
    // Log the current focused document first
    if DocumentKind = 'PCB' then
    begin
        if PCBServer <> nil then
            LogMessage := LogMessage + '. Current PCB: ' + BoolToStr(GetBoardSafe(0) <> nil, True);
    end
    else if DocumentKind = 'SCH' then
    begin
        if SchServer <> nil then
            LogMessage := LogMessage + '. Current SCH: ' + BoolToStr(SchServer.GetCurrentSchDocument <> nil, True);
    end
    else if DocumentKind = 'SCHLIB' then
    begin
        if SchServer <> nil then
        begin
            CurrentDoc := SchServer.GetCurrentSchDocument;
            LogMessage := LogMessage + '. Current SCHLIB: ' + BoolToStr((CurrentDoc <> nil) and (CurrentDoc.ObjectID = eSchLib), True);
        end;
    end;
    
    // ShowMessage(LogMessage); // For debugging
    
    FocusFailure := '';
    // Retrieve the current project
    Project := GetWorkspace.DM_FocusedProject;
    If Project = Nil Then
    begin
        FocusFailure := 'No project is open';
        Exit;
    end;

    // Check if the correct document type is already focused. A screenshot
    // needs the PCB in front; other commands accept a board behind other tabs
    if (DocumentKind = 'PCB') and (PCBServer <> Nil) then
    begin
        if (CommandName = 'take_view_screenshot') then
        begin
            if PcbInFront(0) then
            begin
                Result := True;
                Exit;
            end;
        end
        else if GetBoardSafe(0) <> Nil then
        begin
            Result := True;
            Exit;
        end;
    end
    else if (DocumentKind = 'SCH') and (SchServer <> Nil) then
    begin
        CurrentDoc := SchServer.GetCurrentSchDocument;
        if CurrentDoc <> Nil then
        begin
            Result := True;
            Exit;
        end;
    end
    else if (DocumentKind = 'SCHLIB') and (SchServer <> Nil) then
    begin
        CurrentDoc := SchServer.GetCurrentSchDocument;
        if (CurrentDoc <> Nil) and (CurrentDoc.ObjectId = eSchLib) then
        begin
            Result := True;
            Exit;
        end;
    end
    else if (DocumentKind = 'PCBLIB') and (PCBServer <> Nil) then
    begin
        if GetPcbLibSafe(0) <> Nil then
        begin
            Result := True;
            Exit;
        end;
    end
    else if (DocumentKind = 'OUTJOB') then
    begin
        OutJobPath := GetOpenOutputJob();
        if OutJobPath <> '' then
        begin
            Result := True;
            Exit;
        end;
    end;

    // Try to find and focus the required document type. The focused project
    // is searched first, then every other open project: after a script run
    // the focused project is often the script project itself, which has no
    // design documents at all.
    For P := -1 to GetWorkspace.DM_ProjectCount - 1 Do
    Begin
      if P < 0 then
        Project := GetWorkspace.DM_FocusedProject
      else
      begin
        Project := GetWorkspace.DM_Projects(P);
        if (Project = Nil) or (Project = GetWorkspace.DM_FocusedProject) then Continue;
      end;
      For I := 0 to Project.DM_LogicalDocumentCount - 1 Do
      Begin
        Doc := Project.DM_LogicalDocuments(I);
        If Doc.DM_DocumentKind = DocumentKind Then
        Begin
            DocFound := True;
            // Try to open and focus the document
            Doc.DM_OpenAndFocusDocument;
            // Give it a moment to focus
            Sleep(500);

            // Verify that the document is now focused
            if DocumentKind = 'PCB' then
            begin
                if GetBoardSafe(0) <> Nil then
                begin
                    Result := True;
                    // ShowMessage('Successfully focused PCB document');
                    Exit;
                end;
            end
            else if DocumentKind = 'SCH' then
            begin
                CurrentDoc := SchServer.GetCurrentSchDocument;
                if (CurrentDoc <> Nil) then
                begin
                    Result := True;
                    // ShowMessage('Successfully focused SCH document');
                    Exit;
                end;
            end
            else if DocumentKind = 'SCHLIB' then
            begin
                CurrentDoc := SchServer.GetCurrentSchDocument;
                if (CurrentDoc <> Nil) and (CurrentDoc.ObjectID = eSchLib) then
                begin
                    Result := True;
                    // ShowMessage('Successfully focused SCHLIB document');
                    Exit;
                end;
            end
            else if DocumentKind = 'PCBLIB' then
            begin
                if GetPcbLibSafe(0) <> Nil then
                begin
                    Result := True;
                    Exit;
                end;
            end
            else if DocumentKind = 'OUTJOB' then
            begin
                // An OutJob is not a schematic: SchServer may not even be
                // loaded. Opening it is all the OutJob commands need.
                Result := True;
                Exit;
            end;
        End;
      End;
    End;

    // TODO: Do I want to iterate through all workspace projects to find valid document if it is not current document?
    // Could use IWorkspace.DM_ProjectCount and for loop

    // No matching document found or couldn't be focused
    if not DocFound then
        FocusFailure := 'No ' + DocumentKind + ' document found in any open project'
    else
        FocusFailure := 'Found a ' + DocumentKind + ' document but could not focus it';
    LogScriptError('EnsureDocumentFocused(' + CommandName + '): ' + FocusFailure);
    
    Result := False;
end;

// Zoom the current PCB view to the union bounding box of the given
// components (plus a margin) so a following screenshot shows them clearly.
// Returns the number of components found.
function ZoomToComponents(DesignatorsList: TStringList): Integer;
var
    Board      : IPCB_Board;
    Component  : IPCB_Component;
    Rect       : TCoordRect;
    i          : Integer;
    HaveBounds : Boolean;
    MinX, MinY, MaxX, MaxY : TCoord;
    Margin     : TCoord;
begin
    Result := 0;
    HaveBounds := False;

    Board := GetBoardSafe(0);
    if (Board = nil) then Exit;

    for i := 0 to DesignatorsList.Count - 1 do
    begin
        Component := Board.GetPcbComponentByRefDes(Trim(DesignatorsList[i]));
        if (Component <> nil) then
        begin
            Rect := Component.BoundingRectangleNoNameComment;
            if not HaveBounds then
            begin
                MinX := Rect.Left;
                MaxX := Rect.Right;
                MinY := Rect.Bottom;
                MaxY := Rect.Top;
                HaveBounds := True;
            end
            else
            begin
                if Rect.Left < MinX then MinX := Rect.Left;
                if Rect.Right > MaxX then MaxX := Rect.Right;
                if Rect.Bottom < MinY then MinY := Rect.Bottom;
                if Rect.Top > MaxY then MaxY := Rect.Top;
            end;
            Result := Result + 1;
        end;
    end;

    if HaveBounds then
    begin
        // 10% margin on the larger span, at least 100 mils
        Margin := (MaxX - MinX);
        if (MaxY - MinY) > Margin then Margin := (MaxY - MinY);
        Margin := Margin div 10;
        if Margin < MilsToCoord(100) then Margin := MilsToCoord(100);

        Board.GraphicalView_ZoomOnRect(MinX - Margin, MinY - Margin, MaxX + Margin, MaxY + Margin);
        Board.GraphicalView_ZoomRedraw;
    end;
end;

// Add a screenshot function that supports both PCB and SCH views.
// If DesignatorsList is non-empty (PCB view only), the view is zoomed to
// those components before the server captures the window.
function TakeViewScreenshot(ViewType: String; DesignatorsList: TStringList): String;
var
    Board          : IPCB_Board;
    SchDoc         : ISch_Document;
    ResultProps    : TStringList;
    OutputLines    : TStringList;
    ClassName      : String;
    DocType        : String;
    WindowFound    : Boolean;
    ZoomedCount    : Integer;
    FocusedKind    : String;
    FocusedName    : String;

    // For screenshot thread
    ThreadStarted  : Boolean;
    ScreenshotResult : String;
begin
    // Default result
    Result := '{"success": false, "error": "Failed to initialize screenshot capture"}';
    // The server finds and captures the window itself; nothing here looks
    // for it, so report that honestly instead of an uninitialised value
    WindowFound := False;

    // Determine what type of document we need to focus
    if LowerCase(ViewType) = 'pcb' then
    begin
        DocType := 'PCB';
        ClassName := 'View_Graphical';
    end
    else if LowerCase(ViewType) = 'sch' then
    begin
        DocType := 'SCH';
        ClassName := 'SchView';
    end
    else
    begin
        Result := '{"success": false, "error": "Invalid view type: ' + JSONEscapeString(ViewType) + '. Must be ''pcb'' or ''sch''"}';
        Exit;
    end;

    // Optionally zoom to the requested components before capture
    ZoomedCount := 0;
    if (DocType = 'PCB') and (DesignatorsList <> nil) and (DesignatorsList.Count > 0) then
        ZoomedCount := ZoomToComponents(DesignatorsList);

    // Report what is ACTUALLY focused now that EnsureDocumentFocused has run.
    // The server compares this against the requested view: if no document of
    // the requested kind is open, the focus stays where it was and the
    // capture would otherwise silently show the wrong editor.
    FocusedKind := '';
    FocusedName := '';
    if (Client.CurrentView <> nil) and (Client.CurrentView.OwnerDocument <> nil) then
    begin
        FocusedKind := Client.CurrentView.OwnerDocument.Kind;
        FocusedName := ExtractFileName(Client.CurrentView.OwnerDocument.FileName);
    end;

    // Create result JSON
    ResultProps := TStringList.Create;
    try
        // Add successful result properties
        AddJSONBoolean(ResultProps, 'success', True);
        AddJSONProperty(ResultProps, 'view_type', ViewType);
        AddJSONProperty(ResultProps, 'focused_kind', FocusedKind);
        AddJSONProperty(ResultProps, 'focused_document', FocusedName);
        AddJSONProperty(ResultProps, 'class_filter', ClassName);
        AddJSONBoolean(ResultProps, 'window_found', WindowFound);
        AddJSONInteger(ResultProps, 'zoomed_component_count', ZoomedCount);
        
        // Add signal to the server that it can now capture the screenshot
        AddJSONBoolean(ResultProps, 'ready_for_capture', True);

        // Build final JSON
        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := OutputLines.Text;
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
    end;
end;

// The OutJob a command works on: the requested path when given, else the
// OutJob of the active project, else the first OutJob of any open project.
// '' when there is none.
function ResolveOutJob(Requested: String): String;
var
    Prj : IProject;
    I   : Integer;
begin
    Result := '';
    if (Requested <> '') then
    begin
        if FileExists(Requested) then Result := Requested;
        Exit;
    end;
    Prj := GetActiveProject(0);
    if (Prj <> nil) then
        for I := 0 to Prj.DM_LogicalDocumentCount - 1 do
            if (Prj.DM_LogicalDocuments(I).DM_DocumentKind = 'OUTPUTJOB') then
            begin
                Result := Prj.DM_LogicalDocuments(I).DM_FullPath;
                Exit;
            end;
    Result := GetOpenOutputJob();
end;

// Error object for the OutJob commands
function OutJobError(Msg: String): String;
var
    ResultProps: TStringList;
begin
    ResultProps := TStringList.Create;
    try
        AddJSONBoolean(ResultProps, 'success', False);
        AddJSONProperty(ResultProps, 'error', Msg);
        Result := BuildJSONObject(ResultProps);
    finally
        ResultProps.Free;
    end;
end;

// All output containers (media) of every output group of an OutJob
function GetOutputJobContainers(ROOT_DIR: String; RequestedPath: String): String;
var
    OutJobPath: String;
    IniFile: TIniFile;
    ContainerName, ContainerAction: String;
    G, J: Integer;
    S: String;
    ResultProps: TStringList;
    ContainersArray: TStringList;
    ContainerProps: TStringList;
    OutputLines: TStringList;
begin
    OutJobPath := ResolveOutJob(RequestedPath);
    if OutJobPath = '' then
    begin
        if (RequestedPath <> '') then
            Result := OutJobError('OutJob not found: ' + RequestedPath)
        else
            Result := OutJobError('No OutJob found in the open projects');
        Exit;
    end;

    ResultProps := TStringList.Create;
    ContainersArray := TStringList.Create;
    try
        AddJSONProperty(ResultProps, 'outjob_path', OutJobPath);

        // The OutJob is an INI file: OutputGroup1..N, each with
        // OutputMedium1..M; the numbering has no gaps
        IniFile := TIniFile.Create(OutJobPath);
        try
            G := 1;
            while (IniFile.ReadString('OutputGroup' + IntToStr(G), 'OutputMedium1', DEFAULT) <> DEFAULT) do
            begin
                S := 'OutputGroup' + IntToStr(G);
                J := 1;
                ContainerName := IniFile.ReadString(S, 'OutputMedium1', DEFAULT);
                while (ContainerName <> DEFAULT) do
                begin
                    ContainerAction := IniFile.ReadString(S, 'OutputMedium' + IntToStr(J) + '_Type', DEFAULT);
                    ContainerProps := TStringList.Create;
                    try
                        AddJSONProperty(ContainerProps, 'container_name', ContainerName);
                        AddJSONProperty(ContainerProps, 'container_type', ContainerAction);
                        AddJSONInteger(ContainerProps, 'group', G);
                        ContainersArray.Add(BuildJSONObject(ContainerProps, 1));
                    finally
                        ContainerProps.Free;
                    end;
                    J := J + 1;
                    ContainerName := IniFile.ReadString(S, 'OutputMedium' + IntToStr(J), DEFAULT);
                end;
                G := G + 1;
            end;
        finally
            IniFile.Free;
        end;

        AddJSONBoolean(ResultProps, 'success', True);
        ResultProps.Add(BuildJSONArray(ContainersArray, 'containers'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := WriteJSONToFile(OutputLines, ROOT_DIR + 'temp_outjob_containers.json');
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        ContainersArray.Free;
    end;
end;

// Run output containers of an OutJob by name. Altium's GenerateReport /
// Print processes return nothing, so a container is reported as
// "dispatched"; the server checks the output folder for new files.
function RunOutputJobs(ContainerNames: TStringList; ROOT_DIR: String; RequestedPath: String): String;
var
    OutJobPath: String;
    IniFile: TIniFile;
    ContainerName, ContainerAction, RelativePath: String;
    G, J: Integer;
    S: String;
    ResultProps: TStringList;
    ContainerResults: TStringList;
    ContainerResultProps: TStringList;
    I: Integer;
    ContainerFound: Boolean;
    DispatchedCount: Integer;
    OutJobDoc: IServerDocument;
    OutputLines: TStringList;
begin
    OutJobPath := ResolveOutJob(RequestedPath);
    if OutJobPath = '' then
    begin
        if (RequestedPath <> '') then
            Result := OutJobError('OutJob not found: ' + RequestedPath)
        else
            Result := OutJobError('No OutJob found in the open projects');
        Exit;
    end;

    // Never re-open a document that is already open: that reloads it from
    // disk and drops unsaved edits. (Not OpenLibraryDocument: DelphiScript
    // does not see a function defined further down the same unit.)
    OutJobDoc := Client.GetDocumentByPath(OutJobPath);
    if (OutJobDoc = nil) then
        OutJobDoc := Client.OpenDocument('OUTPUTJOB', OutJobPath);
    if (OutJobDoc = nil) then
    begin
        Result := OutJobError('Could not open OutJob document: ' + OutJobPath);
        Exit;
    end;

    ResultProps := TStringList.Create;
    ContainerResults := TStringList.Create;
    DispatchedCount := 0;
    try
        AddJSONProperty(ResultProps, 'outjob_path', OutJobPath);

        IniFile := TIniFile.Create(OutJobPath);
        try
            for I := 0 to ContainerNames.Count - 1 do
            begin
                ContainerFound := False;
                ContainerResultProps := TStringList.Create;
                try
                    AddJSONProperty(ContainerResultProps, 'container_name', ContainerNames[I]);

                    G := 1;
                    while (not ContainerFound) and
                          (IniFile.ReadString('OutputGroup' + IntToStr(G), 'OutputMedium1', DEFAULT) <> DEFAULT) do
                    begin
                        S := 'OutputGroup' + IntToStr(G);
                        J := 1;
                        ContainerName := IniFile.ReadString(S, 'OutputMedium1', DEFAULT);
                        while (not ContainerFound) and (ContainerName <> DEFAULT) do
                        begin
                            if ContainerName = ContainerNames[I] then
                            begin
                                ContainerFound := True;
                                ContainerAction := IniFile.ReadString(S, 'OutputMedium' + IntToStr(J) + '_Type', DEFAULT);
                                RelativePath := IniFile.ReadString('PublishSettings', 'OutputBasePath' + IntToStr(J), '');

                                // The output processes act on the OutJob in front
                                Client.ShowDocument(OutJobDoc);
                                OutJobDoc.Focus();

                                if ContainerAction = 'GeneratedFiles' then
                                begin
                                    ResetParameters;
                                    AddStringParameter('Action', 'Run');
                                    AddStringParameter('OutputMedium', ContainerName);
                                    AddStringParameter('ObjectKind', 'OutputBatch');
                                    AddStringParameter('OutputBasePath', RelativePath);
                                    RunProcess('WorkspaceManager:GenerateReport');
                                    AddJSONBoolean(ContainerResultProps, 'success', True);
                                    AddJSONBoolean(ContainerResultProps, 'dispatched', True);
                                    DispatchedCount := DispatchedCount + 1;
                                end
                                else if ContainerAction = 'Publish' then
                                begin
                                    ResetParameters;
                                    AddStringParameter('Action', 'PublishToPDF');
                                    AddStringParameter('OutputMedium', ContainerName);
                                    AddStringParameter('ObjectKind', 'OutputBatch');
                                    AddStringParameter('OutputBasePath', RelativePath);
                                    AddStringParameter('DisableDialog', 'True');
                                    RunProcess('WorkspaceManager:Print');
                                    AddJSONBoolean(ContainerResultProps, 'success', True);
                                    AddJSONBoolean(ContainerResultProps, 'dispatched', True);
                                    DispatchedCount := DispatchedCount + 1;
                                end
                                else
                                begin
                                    AddJSONBoolean(ContainerResultProps, 'success', False);
                                    AddJSONProperty(ContainerResultProps, 'error', 'Unsupported container type: ' + ContainerAction);
                                end;
                                AddJSONInteger(ContainerResultProps, 'group', G);
                                AddJSONProperty(ContainerResultProps, 'container_type', ContainerAction);
                                AddJSONProperty(ContainerResultProps, 'relative_path', RelativePath);
                            end;
                            J := J + 1;
                            ContainerName := IniFile.ReadString(S, 'OutputMedium' + IntToStr(J), DEFAULT);
                        end;
                        G := G + 1;
                    end;

                    if not ContainerFound then
                    begin
                        AddJSONBoolean(ContainerResultProps, 'success', False);
                        AddJSONProperty(ContainerResultProps, 'error', 'Container not found: ' + ContainerNames[I]);
                    end;

                    ContainerResults.Add(BuildJSONObject(ContainerResultProps, 1));
                finally
                    ContainerResultProps.Free;
                end;
            end;
        finally
            IniFile.Free;
        end;

        AddJSONBoolean(ResultProps, 'success', DispatchedCount > 0);
        AddJSONInteger(ResultProps, 'total_containers', ContainerNames.Count);
        AddJSONInteger(ResultProps, 'dispatched_containers', DispatchedCount);
        ResultProps.Add(BuildJSONArray(ContainerResults, 'container_results'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := WriteJSONToFile(OutputLines, ROOT_DIR + 'temp_run_outjobs.json');
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        ContainerResults.Free;
    end;
end;

// Helper function to check if a document is open
function IsOpenDoc(Path: String): Boolean;
var
    Project     : IProject;
    ProjectIdx, I  : Integer;
    Doc: IDocument;
begin
    result := False;

    for ProjectIdx := 0 to GetWorkspace.DM_ProjectCount - 1 do
    begin
        Project := GetWorkspace.DM_Projects(ProjectIdx);
        if Project = Nil then Exit;

        if Path = Project.DM_ProjectFullPath then
        begin
            result := True;
            Exit;
        end;

        // Iterate documents
        for I := 0 to Project.DM_LogicalDocumentCount - 1 do
        begin
            Doc := Project.DM_LogicalDocuments(I);
            if Path = Doc.DM_FullPath then
            begin
                result := True;
                Exit;
            end;
        end;
    end;
end;

// A file path in one canonical spelling for comparisons: lower case,
// backslashes, and doubled separators collapsed (a leading \\ of a UNC path
// is kept)
function NormalizedPath(Path: String): String;
var
    Lead : String;
begin
    Result := LowerCase(StringReplace(Trim(Path), '/', '\', REPLACEALL));
    Lead := '';
    if (Copy(Result, 1, 2) = '\\') then
    begin
        Lead := '\\';
        Result := Copy(Result, 3, Length(Result));
    end;
    while (Pos('\\', Result) > 0) do
        Result := StringReplace(Result, '\\', '\', REPLACEALL);
    Result := Lead + Result;
end;

// The open document for a file, or nil. Paths are compared case-
// insensitively with separators normalised: Client.IsDocumentOpen misses a
// path spelled differently, and the file would be opened a second time.
function FindOpenDocument(Path: String): IServerDocument;
var
    i, j   : Integer;
    Module : IServerModule;
    Want   : String;
begin
    Result := nil;
    Want := NormalizedPath(Path);
    for i := 0 to Client.Count - 1 do
    begin
        Module := Client.ServerModule[i];
        if (Module <> nil) then
            for j := 0 to Module.DocumentCount - 1 do
                if (NormalizedPath(Module.Documents[j].FileName) = Want) then
                begin
                    Result := Module.Documents[j];
                    Exit;
                end;
    end;
end;

// Focus a library document ('SchLib' or 'PcbLib'), opening it only when it
// is not open yet: re-opening an open document reloads it from disk and
// silently discards unsaved changes. Returns nil when it cannot be opened.
function OpenLibraryDocument(Kind: String; Path: String): IServerDocument;
begin
    Result := FindOpenDocument(Path);
    if (Result = nil) then
        Result := Client.OpenDocument(Kind, Path);
    if (Result <> nil) then
    begin
        Client.ShowDocument(Result);
        Sleep(500);
    end;
end;

// Mark an open document as changed, so its tab shows it unsaved and Altium
// asks before closing it. Objects a script adds to a library through
// PreProcess/PostProcess do not reliably set the flag (a PCB library never
// does); the user reviews and saves.
procedure MarkDocumentModified(Path: String);
var
    Doc : IServerDocument;
begin
    Doc := FindOpenDocument(Path);
    if (Doc <> nil) then
        Doc.Modified := True;
end;

// ---------------------------------------------------------------------------
// Project-level read-only queries (get_project_info, get_erc_violations).
// Both work on the focused project and never save or modify documents.
// ---------------------------------------------------------------------------

// Error level of an IViolation as text (TErrorLevel).
function ErrorLevelName(Level: Integer): String;
begin
    case Level of
        0: Result := 'no_report';
        1: Result := 'warning';
        2: Result := 'error';
        3: Result := 'fatal';
    else
        Result := 'level_' + IntToStr(Level);
    end;
end;

// Kind of an IComponentVariation as text (TVariationKind).
function VariationKindName(Kind: Integer): String;
begin
    case Kind of
        0: Result := 'none';
        1: Result := 'not_fitted';
        2: Result := 'alternate';
    else
        Result := 'kind_' + IntToStr(Kind);
    end;
end;

// Focused project: parameters, documents (with unsaved-changes flag) and variants
function GetProjectInfo(ROOT_DIR: String): String;
var
    Project      : IProject;
    Doc          : IDocument;
    ServerDoc    : IServerDocument;
    ProjVariant  : IProjectVariant;
    Variation    : IComponentVariation;
    I, J         : Integer;
    SchCount     : Integer;
    ModifiedCount: Integer;
    ResultProps  : TStringList;
    ParamsArray  : TStringList;
    DocsArray    : TStringList;
    VariantsArray: TStringList;
    VariationsArr: TStringList;
    ItemProps    : TStringList;
    OutputLines  : TStringList;
    OpenState    : String;
begin
    // The project of the active document (DM_FocusedProject is "Free
    // Documents" or the script project while a script runs)
    Project := GetActiveProject(0);
    if Project = Nil then
    begin
        Result := 'ERROR: No project is open';
        Exit;
    end;

    ResultProps := TStringList.Create;
    ParamsArray := TStringList.Create;
    DocsArray := TStringList.Create;
    VariantsArray := TStringList.Create;
    try
        AddJSONProperty(ResultProps, 'project_path', Project.DM_ProjectFullPath);

        for I := 0 to Project.DM_ParameterCount - 1 do
        begin
            ItemProps := TStringList.Create;
            try
                AddJSONProperty(ItemProps, 'name', Project.DM_Parameters(I).DM_Name);
                AddJSONProperty(ItemProps, 'value', Project.DM_Parameters(I).DM_Value);
                ParamsArray.Add(BuildJSONObject(ItemProps, 1));
            finally
                ItemProps.Free;
            end;
        end;

        SchCount := 0;
        ModifiedCount := 0;
        for I := 0 to Project.DM_LogicalDocumentCount - 1 do
        begin
            Doc := Project.DM_LogicalDocuments(I);
            if Doc.DM_DocumentKind = 'SCH' then Inc(SchCount);
            ServerDoc := Client.GetDocumentByPath(Doc.DM_FullPath);
            if ServerDoc = Nil then
                OpenState := 'closed'
            else if ServerDoc.Modified then
            begin
                OpenState := 'modified';
                Inc(ModifiedCount);
            end
            else
                OpenState := 'open';
            ItemProps := TStringList.Create;
            try
                AddJSONProperty(ItemProps, 'path', Doc.DM_FullPath);
                AddJSONProperty(ItemProps, 'kind', Doc.DM_DocumentKind);
                AddJSONProperty(ItemProps, 'state', OpenState);
                DocsArray.Add(BuildJSONObject(ItemProps, 1));
            finally
                ItemProps.Free;
            end;
        end;

        for I := 0 to Project.DM_ProjectVariantCount - 1 do
        begin
            ProjVariant := Project.DM_ProjectVariants(I);
            VariationsArr := TStringList.Create;
            ItemProps := TStringList.Create;
            try
                for J := 0 to ProjVariant.DM_VariationCount - 1 do
                begin
                    Variation := ProjVariant.DM_Variations(J);
                    VariationsArr.Add('{"designator": "' + JSONEscapeString(Variation.DM_PhysicalDesignator) +
                        '", "kind": "' + VariationKindName(Variation.DM_VariationKind) + '"}');
                end;
                AddJSONProperty(ItemProps, 'name', ProjVariant.DM_Description);
                ItemProps.Add(BuildJSONArray(VariationsArr, 'variations', 1));
                VariantsArray.Add(BuildJSONObject(ItemProps, 1));
            finally
                ItemProps.Free;
                VariationsArr.Free;
            end;
        end;

        ResultProps.Add(BuildJSONArray(ParamsArray, 'parameters'));
        AddJSONInteger(ResultProps, 'schematic_sheet_count', SchCount);
        AddJSONInteger(ResultProps, 'modified_document_count', ModifiedCount);
        ResultProps.Add(BuildJSONArray(DocsArray, 'documents'));
        ResultProps.Add(BuildJSONArray(VariantsArray, 'variants'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := WriteJSONToFile(OutputLines, ROOT_DIR + 'temp_project_info.json');
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        ParamsArray.Free;
        DocsArray.Free;
        VariantsArray.Free;
    end;
end;

// Compile the focused project (in memory, nothing is saved) and list the
// compiler/ERC violations. Violations live on the project object; the
// per-document DM_ViolationCount does not exist in recent Altium versions.
function GetERCViolations(ROOT_DIR: String; DoCompile: Boolean): String;
var
    Project     : IProject;
    Violation   : IViolation;
    I, Level    : Integer;
    NFatal, NError, NWarning : Integer;
    ResultProps : TStringList;
    ViolArray   : TStringList;
    ItemProps   : TStringList;
    OutputLines : TStringList;
begin
    // The project of the active document (DM_FocusedProject is "Free
    // Documents" or the script project while a script runs)
    Project := GetActiveProject(0);
    if Project = Nil then
    begin
        Result := 'ERROR: No project is open';
        Exit;
    end;

    if DoCompile then
        Project.DM_Compile;

    NFatal := 0; NError := 0; NWarning := 0;

    ResultProps := TStringList.Create;
    ViolArray := TStringList.Create;
    try
        for I := 0 to Project.DM_ViolationCount - 1 do
        begin
            Violation := Project.DM_Violations(I);
            Level := Violation.DM_ErrorLevel;
            if Level = 3 then Inc(NFatal);
            if Level = 2 then Inc(NError);
            if Level = 1 then Inc(NWarning);
            ItemProps := TStringList.Create;
            try
                AddJSONProperty(ItemProps, 'level', ErrorLevelName(Level));
                AddJSONProperty(ItemProps, 'type', Violation.DM_DescriptorString);
                AddJSONProperty(ItemProps, 'detail', Violation.DM_DetailString);
                ViolArray.Add(BuildJSONObject(ItemProps, 1));
            finally
                ItemProps.Free;
            end;
        end;

        AddJSONProperty(ResultProps, 'project_path', Project.DM_ProjectFullPath);
        AddJSONBoolean(ResultProps, 'compiled', DoCompile);
        AddJSONInteger(ResultProps, 'total', ViolArray.Count);
        AddJSONInteger(ResultProps, 'fatal', NFatal);
        AddJSONInteger(ResultProps, 'errors', NError);
        AddJSONInteger(ResultProps, 'warnings', NWarning);
        ResultProps.Add(BuildJSONArray(ViolArray, 'violations'));

        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := WriteJSONToFile(OutputLines, ROOT_DIR + 'temp_erc.json');
        finally
            OutputLines.Free;
        end;
    finally
        ResultProps.Free;
        ViolArray.Free;
    end;
end;

// Every component of the compiled (flattened) project with its comment,
// footprint, library reference, sheet and parameters. Compiles first.
function GetProjectComponents(ROOT_DIR: String; IncludeParameters: Boolean): String;
var
    Project     : IProject;
    Flat        : IDocument;
    Comp        : IComponent;
    I, J        : Integer;
    CompArray   : TStringList;
    CompProps   : TStringList;
    ParamArray  : TStringList;
    ResultProps : TStringList;
    OutputLines : TStringList;
begin
    // The project of the active document (DM_FocusedProject is "Free
    // Documents" or the script project while a script runs)
    Project := GetActiveProject(0);
    if Project = Nil then
    begin
        Result := 'ERROR: No project is open';
        Exit;
    end;
    Project.DM_Compile;
    Flat := Project.DM_DocumentFlattened;
    if Flat = Nil then
    begin
        Result := 'ERROR: Project could not be compiled (no flattened document)';
        Exit;
    end;

    CompArray := TStringList.Create;
    ResultProps := TStringList.Create;
    try
        for I := 0 to Flat.DM_ComponentCount - 1 do
        begin
            Comp := Flat.DM_Components(I);
            CompProps := TStringList.Create;
            ParamArray := TStringList.Create;
            try
                if IncludeParameters then
                    for J := 0 to Comp.DM_ParameterCount - 1 do
                        ParamArray.Add('{"name": "' + JSONEscapeString(Comp.DM_Parameters(J).DM_Name) +
                            '", "value": "' + JSONEscapeString(Comp.DM_Parameters(J).DM_Value) + '"}');
                AddJSONProperty(CompProps, 'designator', Comp.DM_PhysicalDesignator);
                AddJSONProperty(CompProps, 'comment', Comp.DM_Comment);
                AddJSONProperty(CompProps, 'footprint', Comp.DM_Footprint);
                AddJSONProperty(CompProps, 'library_reference', Comp.DM_LibraryReference);
                AddJSONProperty(CompProps, 'sheet', ExtractFileName(Comp.DM_OwnerDocumentFullPath));
                if IncludeParameters then
                    CompProps.Add(BuildJSONArray(ParamArray, 'parameters', 1));
                CompArray.Add(BuildJSONObject(CompProps, 1));
            finally
                CompProps.Free;
                ParamArray.Free;
            end;
        end;

        AddJSONProperty(ResultProps, 'project_path', Project.DM_ProjectFullPath);
        AddJSONInteger(ResultProps, 'component_count', CompArray.Count);
        ResultProps.Add(BuildJSONArray(CompArray, 'components'));
        OutputLines := TStringList.Create;
        try
            OutputLines.Text := BuildJSONObject(ResultProps);
            Result := WriteJSONToFile(OutputLines, ROOT_DIR + 'temp_project_components.json');
        finally
            OutputLines.Free;
        end;
    finally
        CompArray.Free;
        ResultProps.Free;
    end;
end;
