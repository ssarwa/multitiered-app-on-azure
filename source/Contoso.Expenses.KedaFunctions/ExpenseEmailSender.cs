using System;
using Microsoft.Azure.WebJobs;
using Microsoft.Azure.WebJobs.Host;
using Microsoft.Extensions.Logging;
using Contoso.Expenses.Common.Models;
using Newtonsoft.Json;
using SendGrid;
using SendGrid.Helpers.Mail;

namespace Contoso.Expenses.KedaFunctions
{
    public static class ExpenseEmailSender
    {
        [FunctionName("ExpenseEmailSender")]
        public static void Run([QueueTrigger("contosoexpenses", Connection = "AzureWebJobsStorage")]string expenseItem, ILogger log, [SendGrid(ApiKey = "SENDGRID_API_KEY")] out SendGridMessage message)
        {
            Expense expense = JsonConvert.DeserializeObject<Expense>(expenseItem);

            string emailFrom = expense.SubmitterEmail;
            string emailTo = expense.ApproverEmail;
            string emailSubject = $"New Expense for the amount of ${expense.Amount} submitted";
            string emailBody = $"Hello {expense.ApproverEmail}, <br/> New Expense report submitted for the purpose of: {expense.Purpose}. <br/> Please review as soon as possible. <br/> <br/> <br/> This is a auto generated email, please do not reply to this email";

            log.LogInformation($"Email Subject: {emailSubject}");
            log.LogInformation($"Email body: {emailBody}");

            message = new SendGridMessage();
            message.AddTo(emailTo);
            message.AddContent(MimeType.Html, emailBody);
            message.SetFrom(new EmailAddress(emailFrom));
            message.SetSubject(emailSubject);

            log.LogInformation($"Email sent successfully to: {emailTo}");
        }
    }
}
