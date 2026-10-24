// Isolated DelphiScript sandbox used by the run_altium_script MCP tool.
//
// This is deliberately a SEPARATE script project from Altium_API: a compile
// error or crash in user-supplied script must never break the working MCP
// tooling.
//
// SandboxLog() flushes to disk on every call, so when a script dies silently
// (Altium leaves it paused in the debugger with no dialog) the log still shows
// the last step that completed - the statement after it is the culprit.

const
    REPLACEALL = 1;
    // Set per run by the run_altium_script tool; names that run's log, result
    // and start-marker files. '' (as in the template) is a probe run.
    SBX_RUN_ID = '';

var
    LogLines : TStringList;
    LogPath  : String;
    OutPath  : String;
    // Scratch variables: DelphiScript has no inline declarations, so scripts
    // passed to the tool reuse these rather than declaring their own.
    S1, S2, S3 : String;
    I1, I2, I3 : Integer;
    B1         : Integer;
    Obj1, Obj2, Obj3, Obj4, Obj5 : IDispatch;
    List1      : TStringList;
    IntMan     : IIntegratedLibraryManager;
    DbDoc      : IDatabaseLibDocument;
    // Set by the tool: the document the script works on ('' = auto) and
    // whether the script needs a PCB board / schematic document at all.
    // SandboxBoard / SandboxSchDoc replace GetCurrentPCBBoard /
    // GetCurrentSchDocument in the script text, so a script keeps working
    // when the user has switched Altium to another tab meanwhile.
    SbxTargetPath : String;
    SbxNeedBoard  : Integer;
    SbxNeedSch    : Integer;
    SbxError      : String;

procedure SandboxLog(Msg: String);
begin
    LogLines.Add(Msg);
    LogLines.SaveToFile(LogPath);
end;

function SbxLower(S: String): String;
begin
    Result := LowerCase(StringReplace(S, '/', '\', REPLACEALL));
end;

// The open server document for a path, or nil
function SbxFindOpen(Path: String): IServerDocument;
var
    i, j   : Integer;
    Module : IServerModule;
begin
    Result := nil;
    for i := 0 to Client.Count - 1 do
    begin
        Module := Client.ServerModule[i];
        if (Module <> nil) then
            for j := 0 to Module.DocumentCount - 1 do
                if (SbxLower(Module.Documents[j].FileName) = SbxLower(Path)) then
                begin
                    Result := Module.Documents[j];
                    Exit;
                end;
    end;
end;

// Bring a document to the front, opening it only if it is not open yet
// (re-opening reloads from disk and drops unsaved edits)
function SbxActivate(Kind: String; Path: String): Integer;
var
    Doc : IServerDocument;
begin
    Result := 0;
    if (Path = '') or (not FileExists(Path)) then Exit;
    Doc := SbxFindOpen(Path);
    if (Doc = nil) then
        Doc := Client.OpenDocument(Kind, Path);
    if (Doc = nil) then Exit;
    Client.ShowDocument(Doc);
    Result := 1;
end;

// First document of a kind ('PCB' or 'SCH') in the focused project, then in
// any open project; '' if none
function SbxProjectDoc(Kind: String): String;
var
    WS      : IWorkspace;
    Prj     : IProject;
    i, j    : Integer;
begin
    Result := '';
    WS := GetWorkspace;
    if (WS = nil) then Exit;
    Prj := WS.DM_FocusedProject;
    if (Prj <> nil) then
        for i := 0 to Prj.DM_LogicalDocumentCount - 1 do
            if (UpperCase(Prj.DM_LogicalDocuments(i).DM_DocumentKind) = Kind) then
            begin
                Result := Prj.DM_LogicalDocuments(i).DM_FullPath;
                Exit;
            end;
    for j := 0 to WS.DM_ProjectCount - 1 do
    begin
        Prj := WS.DM_Projects(j);
        for i := 0 to Prj.DM_LogicalDocumentCount - 1 do
            if (UpperCase(Prj.DM_LogicalDocuments(i).DM_DocumentKind) = Kind) then
            begin
                Result := Prj.DM_LogicalDocuments(i).DM_FullPath;
                Exit;
            end;
    end;
end;

// The PCB board the script works on, never raising. Order: the target
// document, the current board, the open board of the focused project.
function SandboxBoard(Dummy: Integer): IPCB_Board;
var
    P : String;
begin
    Result := nil;
    if (PCBServer = nil) then
    begin
        // PCB server not loaded yet: opening a PcbDoc loads it
        P := SbxTargetPath;
        if (P = '') then P := SbxProjectDoc('PCB');
        SbxActivate('PCB', P);
        if (PCBServer = nil) then Exit;
    end;
    if (SbxTargetPath <> '') and (UpperCase(ExtractFileExt(SbxTargetPath)) = '.PCBDOC') then
    begin
        Result := PCBServer.GetPCBBoardByPath(SbxTargetPath);
        if (Result = nil) then
        begin
            SbxActivate('PCB', SbxTargetPath);
            Result := PCBServer.GetPCBBoardByPath(SbxTargetPath);
        end;
        Exit;
    end;
    Result := PCBServer.GetCurrentPCBBoard;
    if (Result <> nil) then Exit;
    P := SbxProjectDoc('PCB');
    if (P = '') then Exit;
    Result := PCBServer.GetPCBBoardByPath(P);
    if (Result = nil) then
    begin
        SbxActivate('PCB', P);
        Result := PCBServer.GetPCBBoardByPath(P);
    end;
end;

// The schematic document the script works on, never raising
function SandboxSchDoc(Dummy: Integer): ISch_Document;
var
    P : String;
begin
    Result := nil;
    P := SbxTargetPath;
    if (P <> '') and (Pos('.SCH', UpperCase(ExtractFileExt(P))) = 1) then
    begin
        if (SchServer <> nil) then
            Result := SchServer.GetSchDocumentByPath(P);
        if (Result = nil) then
        begin
            if (UpperCase(ExtractFileExt(P)) = '.SCHLIB') then
                SbxActivate('SCHLIB', P)
            else
                SbxActivate('SCH', P);
            if (SchServer <> nil) then
                Result := SchServer.GetSchDocumentByPath(P);
        end;
        Exit;
    end;
    if (SchServer = nil) then Exit;
    Result := SchServer.GetCurrentSchDocument;
    if (Result <> nil) then Exit;
    P := SbxProjectDoc('SCH');
    if (P = '') then Exit;
    Result := SchServer.GetSchDocumentByPath(P);
    if (Result = nil) then
    begin
        SbxActivate('SCH', P);
        Result := SchServer.GetSchDocumentByPath(P);
    end;
end;

// Checks run before the script body: when the document it needs cannot be
// found the body is skipped and a readable error returned instead of a
// nil dereference that wedges the executor
function SandboxReady(Dummy: Integer): Integer;
begin
    Result := 0;
    SbxError := '';
    if (SbxTargetPath <> '') and (not FileExists(SbxTargetPath)) then
    begin
        SbxError := 'document not found: ' + SbxTargetPath;
        Exit;
    end;
    if (SbxNeedBoard = 1) and (SandboxBoard(0) = nil) then
    begin
        SbxError := 'no PCB board available: the active document is not a PCB and no PcbDoc '
                  + 'was found in the open projects (pass document=<path to .PcbDoc>)';
        Exit;
    end;
    if (SbxNeedSch = 1) and (SandboxSchDoc(0) = nil) then
    begin
        SbxError := 'no schematic document available: the active document is not a schematic '
                  + 'and none was found in the open projects (pass document=<path to .SchDoc>)';
        Exit;
    end;
    if (SbxTargetPath <> '') and (SbxNeedBoard = 0) and (SbxNeedSch = 0) then
        SbxActivate(UpperCase(Copy(ExtractFileExt(SbxTargetPath), 2, 20)), SbxTargetPath);
    Result := 1;
end;

procedure Run;
var
    ResultText : String;
    OutLines   : TStringList;
    GoPath     : String;
begin
    if (SBX_RUN_ID <> '') then
    begin
        // The tool creates the start marker before launching and removes it
        // when the call returns. A launch that only gets here later (Altium
        // was busy, the call timed out or was cancelled) must not run a
        // script whose caller was already told it did not run.
        GoPath := 'C:\Users\Public\altium_mcp\sandbox_go_' + SBX_RUN_ID;
        if not FileExists(GoPath) then Exit;
        DeleteFile(GoPath);
        LogPath := 'C:\Users\Public\altium_mcp\sandbox_log_' + SBX_RUN_ID + '.txt';
        OutPath := 'C:\Users\Public\altium_mcp\sandbox_result_' + SBX_RUN_ID + '.json';
    end
    else
    begin
        LogPath := 'C:\Users\Public\altium_mcp\sandbox_log.txt';
        OutPath := 'C:\Users\Public\altium_mcp\sandbox_result.json';
    end;
    LogLines := TStringList.Create;
    ResultText := '{"sandbox": "no result set"}';
    SandboxLog('sandbox start');

    try
        // === BEGIN EXPERIMENT (rewritten by the run_altium_script tool) ===
        ResultText := '{"probe": "alive"}';
        // === END EXPERIMENT ===
    except
        SandboxLog('EXCEPTION escaped the script body');
        ResultText := '{"error": "exception escaped script - see log for last step"}';
    end;

    SandboxLog('sandbox end');

    OutLines := TStringList.Create;
    try
        OutLines.Text := ResultText;
        OutLines.SaveToFile(OutPath);
    finally
        OutLines.Free;
        LogLines.Free;
    end;
end;
