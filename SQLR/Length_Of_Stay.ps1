﻿<#
.SYNOPSIS
Script to predict the length of stay for patients in a hospital, using SQL Server and MRS. 
#>

[CmdletBinding()]
param(
# SQL server address
[parameter(Mandatory=$true,ParameterSetName = "LoS")]
[ValidateNotNullOrEmpty()] 
[String]    
$ServerName = "",

# SQL server database name
[parameter(Mandatory=$true,ParameterSetName = "LoS")]
[ValidateNotNullOrEmpty()]
[String]
$DBName = "",

[parameter(Mandatory=$true,ParameterSetName = "LoS")]
[ValidateNotNullOrEmpty()]
[String]
$username ="",


[parameter(Mandatory=$true,ParameterSetName = "LoS")]
[ValidateNotNullOrEmpty()]
[String]
$password ="",

[parameter(Mandatory=$true,ParameterSetName = "LoS")]
[ValidateNotNullOrEmpty()]
[String]
$uninterrupted="",

[parameter(Mandatory=$false,ParameterSetName = "LoS")]
[ValidateNotNullOrEmpty()]
[String]
$dataPath = ""
)

$scriptPath = Get-Location
$filePath = $scriptPath.Path+ "\"
$error = $scriptPath.Path + "\output.log"

if ($dataPath -eq "")
{
##########################################################################
# Script level variables
##########################################################################
$parentPath = Split-Path -parent $scriptPath
$dataPath = $parentPath + "/Data/"
}
##########################################################################
# Function wrapper to invoke SQL command
##########################################################################
function ExecuteSQL
{
param(
[String]
$sqlscript
)
    Invoke-Sqlcmd -ServerInstance $ServerName  -Database $DBName -Username $username -Password $password -InputFile $sqlscript -QueryTimeout 200000
}
##########################################################################
# Function wrapper to invoke SQL query
##########################################################################
function ExecuteSQLQuery
{
param(
[String]
$sqlquery
)
    Invoke-Sqlcmd -ServerInstance $ServerName  -Database $DBName -Username $username -Password $password -Query $sqlquery -QueryTimeout 200000
}

##########################################################################
# Get connection string
##########################################################################
function GetConnectionString
{
    $connectionString = "Driver=SQL Server;Server=$ServerName;Database=$DBName;UID=$username;PWD=$password"
     $connectionString
}

$ServerName2="localhost"

function GetConnectionString2
{
    $connectionString2 = "Driver=SQL Server;Server=$ServerName2;Database=$DBName;UID=$username;PWD=$password"
     $connectionString2
}

##########################################################################
# Construct the SQL connection strings
##########################################################################
$connectionString = GetConnectionString
$connectionString2 = GetConnectionString2

##########################################################################
# Check if the SQL server or database exists
##########################################################################
$query = "IF NOT EXISTS(SELECT * FROM sys.databases WHERE NAME = '$DBName') CREATE DATABASE $DBName"
Invoke-Sqlcmd -ServerInstance $ServerName -Username $username -Password $password -Query $query -ErrorAction SilentlyContinue
if ($? -eq $false)
{
    Write-Host -ForegroundColor Red "Failed the test to connect to SQL server: $ServerName database: $DBName !"
    Write-Host -ForegroundColor Red "Please make sure: `n`t 1. SQL Server: $ServerName exists;
                                     `n`t 2. SQL database: $DBName exists;
                                     `n`t 3. SQL user: $username has the right credential for SQL server access."
    exit
}

$query = "USE $DBName;"
Invoke-Sqlcmd -ServerInstance $ServerName -Username $username -Password $password -Query $query 


##########################################################################
# Loading the data
##########################################################################
$startTime= Get-Date
Write-Host "Start time is:" $startTime  


if ($uninterrupted -eq 'y' -or $uninterrupted -eq 'Y')
{
   try
       {

        # create raw table
        Write-Host -ForeGroundColor 'green' ("Create SQL table.")
        $script = $filePath + "step0_create_table.sql"
        ExecuteSQL $script
    
        Write-Host -ForeGroundColor 'green' ("Populate SQL table.")
        $dataList = "LengthOfStay"
		
		# upload csv files into SQL tables
        foreach ($dataFile in $dataList)
        {
            $destination = $dataPath + $dataFile + ".csv"
            $tableName = $DBName + ".dbo." + $dataFile
            $tableSchema = $dataPath + $dataFile + ".xml"
            bcp $tableName format nul -c -x -f $tableSchema  -U $username -S $ServerName -P $password  -t ',' -e $error
            bcp $tableName in $destination -t ',' -S $ServerName -f $tableSchema -F 2 -C "RAW" -b 50000 -U $username -P $password -e $error
        }
    }
    catch
    {
        Write-Host -ForegroundColor DarkYellow "Exception in populating database tables:"
        Write-Host -ForegroundColor Red $Error[0].Exception 
        throw
    }

    # create the stored procedures for preprocessing
    $script = $filepath + "step1_data_processing.sql"
    ExecuteSQL $script

    # execute the NA replacement
    Write-Host -ForeGroundColor 'Cyan' (" Replacing missing values with the mean and mode...")
    $query = "EXEC fill_NA_mode_mean"
    ExecuteSQLQuery $query


    # create the stored procedure for feature engineering
    $script = $filepath + "step2_feature_engineering.sql"
    ExecuteSQL $script

    # execute the feature engineering
    Write-Host -ForeGroundColor 'Cyan' (" Computing new features...")
    $query = "EXEC feature_engineering"
    ExecuteSQLQuery $query

    # create the stored procedure for splitting into train and test data sets
    $script = $filepath + "step3a_splitting.sql"
    ExecuteSQL $script

    # execute the procedure
    $splitting_percent = 70
    Write-Host -ForeGroundColor 'Cyan' (" Splitting the data set...")
    $query = "EXEC splitting $splitting_percent"
    ExecuteSQLQuery $query

    # create the stored procedure for training 
    $script = $filepath + "step3b_training.sql"
    ExecuteSQL $script

    # execute the training 
    Write-Host -ForeGroundColor 'Cyan' (" Training Gradient Boosted Trees (rxFastTrees implementation)...")
    $modelName = 'GBT'
    $query = "EXEC train_model $modelName, '$connectionString2'"
    ExecuteSQLQuery $query
     
    # create the stored procedure for predicting 
    $script = $filepath + "step3c_testing_evaluating.sql"
    ExecuteSQL $script

    # execute the evaluation 
    Write-Host -ForeGroundColor 'Cyan' (" Testing and Evaluating Gradient Boosted Trees...")
    $query = "EXEC test_evaluate_models @connectionString = '$connectionString2'"
    ExecuteSQLQuery $query
    $query = "EXEC prediction_results"
    ExecuteSQLQuery $query


    Write-Host -foregroundcolor 'green'("Length of Stay Prediction Workflow Finished Successfully!")
}

if ($uninterrupted -eq 'n' -or $uninterrupted -eq 'N')
{

##########################################################################
# Create input table and populate with data from csv file.
##########################################################################
Write-Host -foregroundcolor 'green' ("Step 0: Create and populate table in Database" -f $dbname)
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
if ($ans -eq 'E' -or $ans -eq 'e')
{
    return
} 
if ($ans -eq 'y' -or $ans -eq 'Y')
{
    try
    {
        # create raw table
        Write-Host -ForeGroundColor 'green' ("Create SQL table.")
        $script = $filePath + "step0_create_table.sql"
        ExecuteSQL $script
    
        Write-Host -ForeGroundColor 'green' ("Populate SQL table.")
        $dataList = "LengthOfStay"
		
		# upload csv files into SQL tables
        foreach ($dataFile in $dataList)
        {
            $destination = $dataPath + $dataFile + ".csv"
            $tableName = $DBName + ".dbo." + $dataFile
            $tableSchema = $dataPath + $dataFile + ".xml"
            bcp $tableName format nul -c -x -f $tableSchema  -U $username -S $ServerName -P $password  -t ',' -e $error
            bcp $tableName in $destination -t ',' -S $ServerName -f $tableSchema -F 2 -C "RAW" -b 50000 -U $username -P $password -e $error
        }
    }
    catch
    {
        Write-Host -ForegroundColor DarkYellow "Exception in populating database tables:"
        Write-Host -ForegroundColor Red $Error[0].Exception 
        throw
    }
}

##########################################################################
# Create and execute the stored procedure for data processing
##########################################################################
Write-Host -foregroundcolor 'green' ("Step 1: Data Processing")
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
if ($ans -eq 'E' -or $ans -eq 'e')
{
    return
} 
if ($ans -eq 'y' -or $ans -eq 'Y')
{
    # create the stored procedures for preprocessing
    $script = $filepath + "step1_data_processing.sql"
    ExecuteSQL $script

    # execute the NA replacement
    $ans2 = Read-Host 'Replacing missing values with mode and mean [M/m] or with missing and -1 [miss]?'
    if ($ans2 -eq 'M' -or $ans -eq 'm')
    {
        Write-Host -ForeGroundColor 'Cyan' (" Replacing missing values with mode and mean ...")
        $query = "EXEC fill_NA_mode_mean "
        ExecuteSQLQuery $query
    }
    else
    {
        Write-Host -ForeGroundColor 'Cyan' (" Replacing missing values with missing and -1 ...")
        $query = "EXEC fill_NA_explicit "
        ExecuteSQLQuery $query
    }

}

##########################################################################
# Create and execute the stored procedure for feature engineering
##########################################################################
Write-Host -foregroundcolor 'green' ("Step 2: Feature Engineering")
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
if ($ans -eq 'E' -or $ans -eq 'e')
{
    return
} 
if ($ans -eq 'y' -or $ans -eq 'Y')
{
    # create the stored procedure for feature engineering
    $script = $filepath + "step2_feature_engineering.sql"
    ExecuteSQL $script

    # execute the feature engineering
    $output1 = Read-Host 'Output table name? Type D or d for default (LoS)'
    if ($output1 -eq 'D' -or $output1 -eq 'd')
    {
        $output1 = 'LoS'
    }
    Write-Host -ForeGroundColor 'Cyan' (" Computing new features...")
    $query = "EXEC feature_engineering 'LengthOfStay', $output1"
    ExecuteSQLQuery $query
}

if ($ans -eq 's' -or $ans -eq 'S')
{
    $output1 = 'LoS'
}
##########################################################################
# Create and execute the stored procedure to split data into train/test
##########################################################################

Write-Host -foregroundcolor 'green' ("Step 3a: Split the data into train and test")
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
if ($ans -eq 'E' -or $ans -eq 'e')
{
    return
} 
if ($ans -eq 'y' -or $ans -eq 'Y')
{
    # create the stored procedure for splitting into train and test data sets
    $script = $filepath + "step3a_splitting.sql"
    ExecuteSQL $script

    # execute the procedure
    $splitting_percent = Read-Host 'Split Percent (e.g. Type 70 for 70% in training set) ?'
    $output2 = Read-Host 'Name of the table storing the ID of the training set? Type D or d for default (Train_Id)'
    if ($output2 -eq 'D' -or $output2 -eq 'd')
    {
        $output2 = 'Train_Id'
    }

    Write-Host -ForeGroundColor 'Cyan' (" Splitting the data set...")
    $query = "EXEC splitting $splitting_percent, $output1, $output2"
    ExecuteSQLQuery $query
}

if ($ans -eq 's' -or $ans -eq 'S')
{
    $output2 = 'Train_Id'
}

##########################################################################
# Create and execute the stored procedure for Training 
##########################################################################

Write-Host -foregroundcolor 'green' ("Step 3b: Models Training")
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
if ($ans -eq 'E' -or $ans -eq 'e')
{
    return
} 
if ($ans -eq 'y' -or $ans -eq 'Y')
{
    # create the stored procedure for training 
    $script = $filepath + "step3b_training.sql"
    ExecuteSQL $script

    # execute the training 
    $ans = Read-Host 'Train Random Forest (rxDForest implementation): Yes [y|Y], Exit [e|E], Skip [s|S]?'
    if ($ans -eq 'E' -or $ans -eq 'e')
    {
        return
    } 
    if ($ans -eq 'y' -or $ans -eq 'Y')
    {
    Write-Host -ForeGroundColor 'Cyan' (" Training Random Forest (rxDForest implementation) ...")
    $modelName = 'RF'
    $query = "EXEC train_model $modelName,'$connectionString2', $output1, $output2"
    ExecuteSQLQuery $query
    }

    $ans = Read-Host 'Train Gradient Boosted Trees (rxFastTrees implementation): Yes [y|Y], Exit [e|E], Skip [s|S]?'
    if ($ans -eq 'E' -or $ans -eq 'e')
    {
        return
    } 
    if ($ans -eq 'y' -or $ans -eq 'Y')
    {
    Write-Host -ForeGroundColor 'Cyan' (" Training Gradient Boosted Trees (rxFastTrees implementation)  ...")
    $modelName = 'GBT'
    $query = "EXEC train_model $modelName, '$connectionString2', $output1, $output2"
    ExecuteSQLQuery $query
    }
}

##########################################################################
# Create and execute the stored procedure for models evaluation
##########################################################################

Write-Host -foregroundcolor 'green' ("Step 3c: Models Evaluation")
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
if ($ans -eq 'E' -or $ans -eq 'e')
{
    return
} 
if ($ans -eq 'y' -or $ans -eq 'Y')
{
    # create the stored procedure for predicting 
    $script = $filepath + "step3c_testing_evaluating.sql"
    ExecuteSQL $script

    # execute the evaluation
    $output3 = Read-Host 'Name of the table storing the performance metrics? Type D or d for default (Metrics)'
    if ($output3 -eq 'D' -or $output3 -eq 'd')
    {
        $output3 = 'Metrics'
    }
    Write-Host -ForeGroundColor 'Cyan' (" Testing and Evaluating the model(s)...")
    $models = "'RF', 'GBT'"
    $query = "EXEC test_evaluate_models $models, '$connectionString2', $output3, $output1, $output2"
    ExecuteSQLQuery $query

}

Write-Host -foregroundcolor 'green'("Length of Stay Prediction Workflow Finished Successfully!")
}

$endTime =Get-Date
$totalTime = ($endTime-$startTime).ToString()
Write-Host "Finished running at:" $endTime
Write-Host "Total time used: " -foregroundcolor 'green' $totalTime.ToString()
